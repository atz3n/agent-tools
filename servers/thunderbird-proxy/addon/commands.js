// Command handlers executed on behalf of the thunderbird-proxy.
// The proxy only ever dispatches names from its closed command set; anything
// else is refused here too, so the wire can never drive arbitrary code.
/* global browser */

const ProxyCommands = {
  handlers: {
    async "accounts.list"(params) {
      // Query params arrive as strings — an explicit true (JSON boolean or
      // the string "true") is the only thing that includes sub-folders;
      // Boolean("false") would have been true.
      const withSubFolders = params.includeSubFolders === true || params.includeSubFolders === "true";
      const accounts = await browser.accounts.list(withSubFolders);
      return { accounts: accounts.map(slimAccount) };
    },

    async "identities.list"(params) {
      const identities = await browser.identities.list(params.account || undefined);
      return { identities: identities.map((i) => ({ id: i.id, accountId: i.account ? i.account.id : undefined, email: i.email, name: i.name })) };
    },

    async "folders.list"(params) {
      if (!params.account) throw new Error("account is required");
      const folders = await browser.folders.query({ accountId: params.account });
      return { folders: folders.map(slimFolder) };
    },

    async "folders.create"(params) {
      const parentId = await resolveFolderId(params); // parentFolderId arrives as folderId
      const folder = await browser.folders.create(parentId, params.name);
      return { folder: slimFolder(folder) };
    },

    async "folders.update"(params) {
      // Renaming onto an existing name can leave Thunderbird hanging on a
      // conflict prompt that never resolves — refuse up front instead.
      const all = await browser.folders.query({});
      const target = all.find((f) => f.id === params.folder_id);
      if (!target) throw new Error(`folder not found: ${params.folder_id}`);
      const parentPath = target.path.slice(0, target.path.lastIndexOf("/"));
      const wanted = `${parentPath}/${params.name}`.toLowerCase();
      const clash = all.some(
        (f) => f.id !== target.id && f.accountId === target.accountId && f.path.toLowerCase() === wanted
      );
      if (clash) throw new Error(`cannot rename to "${params.name}" — a folder already exists there`);
      // On recent Thunderbird folders.update only edits isFavorite —
      // renaming is its own API (folders.rename, TB 68+).
      const folder = await browser.folders.rename(params.folder_id, params.name);
      return { folder: slimFolder(folder) };
    },

    async "folders.delete"(params) {
      // A folder that still holds mail is never deleted — and neither is one
      // whose sub-folders do (deleting a folder deletes its whole subtree).
      const subtree = new Set([params.folder_id]);
      const walk = (folders) => {
        for (const folder of folders) {
          subtree.add(folder.id);
          if (folder.subFolders) walk(folder.subFolders);
        }
      };
      walk(await browser.folders.getSubFolders(params.folder_id, true));
      const nonEmpty = await browser.folders.query({ hasMessages: true });
      if (nonEmpty.some((folder) => subtree.has(folder.id))) {
        throw new Error("folder is not empty — move or trash its messages first");
      }
      try {
        await browser.folders.delete(params.folder_id);
      } catch (error) {
        // Current Thunderbird builds fail to delete IMAP folders (bug 2013929);
        // name the likely cause instead of leaving "unknown reasons" behind.
        if (/unknown reasons/.test(error.message)) {
          throw new Error(`folder not deleted: Thunderbird could not delete it on the server (IMAP folder deletion is broken in current Thunderbird builds, bug 2013929)`);
        }
        throw error;
      }
      return { deleted: true };
    },

    async "messages.list"(params) {
      const folderId = await resolveFolderId(params);
      const limit = clampCount(params.limit, 25, 200);
      const offset = clampCount(params.offset, 0, 100000);
      // options accepts only sortType/sortOrder (TB 148+) — no maxCount; pages
      // come via continueList until the MessageList id turns null.
      let page = await browser.messages.list(folderId, { sortType: "date", sortOrder: "descending" });
      let messages = page.messages;
      while (messages.length < offset + limit && page.id != null) {
        page = await browser.messages.continueList(page.id);
        messages = messages.concat(page.messages);
      }
      if (page.id != null) await browser.messages.abortList(page.id);
      return { messages: messages.slice(offset, offset + limit).map(slimMessage) };
    },

    async "messages.search"(params) {
      const queryInfo = {};
      for (const key of ["subject", "body", "author"]) {
        if (params[key]) queryInfo[key] = params[key];
      }
      if (params.to) queryInfo.recipients = params.to;
      if (params.folderId || params.folder) {
        queryInfo.folderId = await resolveFolderId(params); // singular "folderId", TB 121+
      } else if (params.account) {
        queryInfo.accountId = params.account;
      }
      // The read-state query property has flip-flopped across TB versions
      // (unread -> read) — try whichever the running schema accepts.
      const flagVariants =
        params.unread === undefined
          ? [{}]
          : [
              { read: String(params.unread) === "false" },
              { unread: String(params.unread) !== "false" },
            ];
      if (!Object.keys(queryInfo).length && flagVariants.length === 1) {
        throw new Error("at least one of subject, body, author, to, unread, account/folder is required");
      }
      let page = null;
      let lastError = new Error("messages.query failed");
      for (const flag of flagVariants) {
        try {
          page = await browser.messages.query({ ...queryInfo, ...flag });
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (!page) throw lastError;
      let messages = page.messages;
      while (page.id != null && messages.length < 500) {
        page = await browser.messages.continueList(page.id);
        messages = messages.concat(page.messages);
      }
      if (page.id != null) await browser.messages.abortList(page.id);
      return { messages: messages.slice(0, 500).map(slimMessage) };
    },

    async "message.get"(params) {
      const id = messageKey(params.message_id); // MessageId is an integer (TB 122+)
      const header = await browser.messages.get(id);
      const full = await browser.messages.getFull(id, { decodeContent: true });
      return { header: slimMessage(header), parts: full.parts };
    },

    async "message.send"(params) {
      if (typeof browser.messages.sendMessage === "function") {
        const result = await browser.messages.sendMessage(buildOutgoing(params), { mode: "sendNow" });
        return { sent: true, message: slimMessage(firstMessage(result)) };
      }
      // Some TB builds gate messages.sendMessage behind a "messages.send"
      // permission the manifest validator refuses to accept — send through a
      // compose window instead (the pre-153 path; the window flashes open
      // and closes itself once the message is away).
      const tab = await browser.compose.beginNew(undefined, buildComposeDetails(params));
      await browser.compose.sendMessage(tab.id, { mode: "sendNow" });
      return { sent: true, message: {} };
    },

    async "message.draft"(params) {
      const result = await browser.messages.saveMessage(buildOutgoing(params));
      return { draft: true, message: slimMessage(firstMessage(result)) };
    },

    async "message.update"(params) {
      const id = messageKey(params.message_id);
      const properties = {};
      for (const key of ["read", "flagged", "tags"]) {
        if (params[key] !== undefined) properties[key] = params[key];
      }
      if (Object.keys(properties).length) await browser.messages.update(id, properties);
      if (params.moveTo) await browser.messages.move([id], params.moveTo);
      return { updated: true };
    },

    async "message.delete"(params) {
      const id = messageKey(params.message_id);
      // Deletion means "move to Trash", never "purge": deletePermanently is
      // explicitly false (options object, TB 137+ — the boolean form is
      // deprecated), and a message already sitting in a trash-type folder is
      // refused (deleting it again would delete it for good). Current builds
      // mark folders with the specialUse array; the legacy type property is
      // checked too so the guard never fails open.
      const header = await browser.messages.get(id);
      const folder = header.folder || {};
      const uses = folder.specialUse || [];
      if (uses.includes("trash") || folder.type === "trash") {
        throw new Error("message is already in the Trash — the proxy never deletes mail permanently");
      }
      await browser.messages.delete([id], { deletePermanently: false });
      return { deleted: true };
    },
  },

  run(name, params) {
    const handler = this.handlers[name];
    if (!handler) throw new Error(`unknown command: ${name}`);
    return handler(params);
  },
};

// -- helpers -----------------------------------------------------------------

function slimAccount(account) {
  return {
    id: account.id,
    key: account.key,
    name: account.name,
    type: account.type,
    subFolders: account.subFolders ? account.subFolders.map(slimFolder) : undefined,
  };
}

function slimFolder(folder) {
  return {
    id: folder.id,
    accountId: folder.accountId ?? (folder.account ? folder.account.id : undefined),
    name: folder.name,
    path: folder.path,
    type: folder.type,
    specialUse: folder.specialUse,
  };
}

function slimMessage(message) {
  if (!message) return null;
  return {
    id: message.id,
    subject: message.subject,
    author: message.author,
    date: message.date,
    read: message.read,
    starred: message.flagged,
    new: message.new,
    folder: message.folder ? message.folder.name : undefined,
    folderId: message.folder ? message.folder.id : undefined,
    accountId: message.folder ? message.folder.accountId : undefined,
    size: message.size,
  };
}

// MessageId is an integer in the WebExtension API (TB 122+), while the REST
// path hands it over as a string — convert, and fail loudly on garbage.
function messageKey(raw) {
  const id = Number(raw);
  if (!Number.isInteger(id)) throw new Error(`message id must be numeric, got: ${raw}`);
  return id;
}

function buildOutgoing(params) {
  const details = copyRecipients({ subject: params.subject, identityId: params.identityId }, params);
  if (params.isPlainText === false) {
    details.body = params.body;
    details.isPlainText = false;
  } else {
    details.plainTextBody = params.plainTextBody ?? params.body;
    details.isPlainText = true;
  }
  return details;
}

// sendMessage/saveMessage resolve to { messages: [...], ... }, not a bare header.
function firstMessage(result) {
  return result && result.messages ? result.messages[0] : result;
}

// The proxy legalizes empty cc/bcc arrays (only `to` must be non-empty), but
// how Thunderbird treats details.cc = [] is unspecified — treat empty as
// absent so the request matches one where the field was never sent.
function copyRecipients(details, params) {
  for (const key of ["to", "cc", "bcc"]) {
    if (params[key] && params[key].length) details[key] = params[key];
  }
  return details;
}

function buildComposeDetails(params) {
  const details = copyRecipients({ subject: params.subject, identityId: params.identityId }, params);
  // Docs describe body as { format, plainText, html } — the runtime schema
  // demands a plain string, so give it exactly that.
  details.body = String(params.plainTextBody ?? params.body ?? "");
  return details;
}

function clampCount(raw, fallback, max) {
  const value = Number.parseInt(raw, 10);
  if (Number.isNaN(value) || value < 0) return fallback;
  return Math.min(value, max);
}

// Resolve folderId directly, or an `account` + `folder` (name or path) pair,
// or just `folder` (a raw folder id).
async function resolveFolderId(params) {
  if (params.folderId) return params.folderId;
  if (!params.folder) {
    if (params.account) throw new Error("folder is required when account is given");
    throw new Error("folderId (or account + folder) is required");
  }
  if (!params.account) return params.folder; // raw folder id in `folder`
  const folders = await browser.folders.query({ accountId: params.account });
  // Exact name/path wins; otherwise the first case-insensitive hit — Gmail
  // displays "Inbox" while its IMAP path reads "/INBOX", and callers guess.
  const wanted = String(params.folder).toLowerCase();
  const match =
    folders.find((f) => f.name === params.folder || f.path === params.folder) ||
    folders.find((f) => f.name.toLowerCase() === wanted || f.path.toLowerCase() === wanted);
  if (!match) throw new Error(`folder not found: ${params.folder}`);
  return match.id;
}
