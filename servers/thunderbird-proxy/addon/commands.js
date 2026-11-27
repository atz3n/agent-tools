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
      return { identities: identities.map((i) => ({ id: i.id, accountId: i.accountId, email: i.email, name: i.name })) };
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
      if (!target || !target.path) throw new Error(`folder not found: ${params.folder_id}`);
      const parentPath = target.path.slice(0, target.path.lastIndexOf("/"));
      const wanted = `${parentPath}/${params.name}`.toLowerCase();
      const clash = all.some(
        (f) => f.id !== target.id && accountIdOf(f) === accountIdOf(target) && String(f.path ?? "").toLowerCase() === wanted
      );
      if (clash) throw new Error(`cannot rename to "${params.name}" — a folder already exists there`);
      // On recent Thunderbird folders.update only edits isFavorite —
      // renaming is its own API (folders.rename, TB 68+).
      const folder = await browser.folders.rename(params.folder_id, params.name);
      return { folder: slimFolder(folder) };
    },

    async "folders.markRead"(params) {
      // Whole-folder mark-as-read — the one bulk flag the WebExtension API
      // itself exposes; partial selections go through messages.mark.
      const folderId = await resolveFolderId(params);
      await browser.folders.markAsRead(folderId);
      return { markedRead: true, folderId };
    },

    async "folders.delete"(params) {
      // A folder that still holds mail is never deleted — and neither is one
      // whose sub-folders do (deleting a folder deletes its whole subtree).
      // The subtree is derived from paths, not from a tree walk: getSubFolders
      // may return a flat list without subFolders, or ignore `recursive`, and
      // a shrunken subtree would silently let nested mail be deleted.
      const all = await browser.folders.query({});
      const target = all.find((f) => f.id === params.folder_id);
      // A path-less target (real on some builds) would compute a "/" prefix
      // and match every folder in the account — same guard as folders.update.
      if (!target || !target.path) throw new Error(`folder not found: ${params.folder_id}`);
      const targetAccount = accountIdOf(target);
      const prefix = `${target.path.toLowerCase()}/`;
      const inSubtree = (f) =>
        f.id === params.folder_id ||
        (accountIdOf(f) === targetAccount && String(f.path ?? "").toLowerCase().startsWith(prefix));
      const nonEmpty = await browser.folders.query({ hasMessages: true });
      if (nonEmpty.some(inSubtree)) {
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
      // options accepts only sortType/sortOrder — no maxCount; pages
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
        queryInfo.folderId = await resolveFolderId(params);
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
      const id = messageKey(params.message_id);
      const header = await browser.messages.get(id);
      const full = await browser.messages.getFull(id, { decodeContent: true });
      return { header: slimMessage(header), parts: full.parts };
    },

    async "message.send"(params) {
      const result = await browser.messages.sendMessage(buildOutgoing(params), { mode: "sendNow" });
      return { sent: true, message: slimMessage(firstMessage(result)) };
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
      if (params.junk === undefined) {
        if (Object.keys(properties).length) await browser.messages.update(id, properties);
        if (params.moveTo) await browser.messages.move([id], params.moveTo);
        return { updated: true };
      }
      // Junk mirrors the UI's junk button: mark the message, then move it
      // to the account's junk folder — on Gmail-style providers the move
      // is what trains the spam filter. Mark-only when no junk folder can
      // be resolved; the response says which happened.
      await browser.messages.update(id, { ...properties, junk: Boolean(params.junk) });
      let movedToJunk = false;
      if (params.junk) {
        const header = await browser.messages.get(id);
        const accountId = accountIdOf(header.folder);
        const folders = await browser.folders.query(accountId ? { accountId } : {});
        const junkFolder = folders.find((f) => hasSpecialUse(f, "junk"));
        if (junkFolder) {
          await browser.messages.move([id], junkFolder.id);
          movedToJunk = junkFolder.id;
        }
      }
      return { updated: true, movedToJunk };
    },

    async "messages.move"(params) {
      // One Thunderbird call for the whole selection, not one round-trip per
      // message (the per-message version is what hammers IMAP rate limits).
      const ids = params.ids.map(messageKey);
      await browser.messages.move(ids, params.to);
      return { moved: ids.length, folderId: params.to };
    },

    async "messages.mark"(params) {
      // Bulk read/starred. The WebExtension API has no set-level update, so
      // the bundled mailBulk experiment API does it with the folder methods
      // Thunderbird's own UI uses: one set-level call per folder holding the
      // messages, never one call per message. Message ids resolve through the
      // extension's own message manager — the same lookup
      // browser.messages.update does — so no folder is needed.
      const details = { messageIds: params.ids.map(messageKey) };
      if (params.read !== undefined) details.read = params.read;
      if (params.flagged !== undefined) details.flagged = params.flagged;
      const result = await browser.mailBulk.markMessages(details);
      // The experiment never flags a partial batch; surface the stale ids as
      // a real error (a throw from here reaches the agent verbatim).
      if (result.missing.length) {
        throw new Error(`messages not found (ids are per-session — re-list them): ${result.missing.join(", ")}`);
      }
      return { updated: result.updated };
    },

    async "messages.trash"(params) {
      // Same never-destroy rule as a single delete, checked for every id
      // before anything is touched: one already-trashed message refuses the
      // whole batch rather than purging it silently.
      const ids = params.ids.map(messageKey);
      const headers = await Promise.all(ids.map((id) => browser.messages.get(id)));
      for (const [i, header] of headers.entries()) {
        try {
          await assertTrashSafe(header);
        } catch (error) {
          throw new Error(`message ${ids[i]}: ${error.message}`);
        }
      }
      await browser.messages.delete(ids, { deletePermanently: false });
      return { trashed: ids.length };
    },

    async "message.delete"(params) {
      const id = messageKey(params.message_id);
      // Deletion means "move to Trash", never "purge" — deletePermanently
      // is explicitly false.
      await assertTrashSafe(await browser.messages.get(id));
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

// MailFolder.accountId identifies the owning folder account (and thus its
// email identities).
function accountIdOf(folder) {
  return folder.accountId;
}

function trashDeterminable(folder) {
  return Boolean(folder) && Array.isArray(folder.specialUse);
}

// Folder purposes come from the specialUse array.
function hasSpecialUse(folder, use) {
  return (folder.specialUse || []).includes(use);
}

function inTrash(folder) {
  return hasSpecialUse(folder, "trash");
}

// Refuses a delete that would purge mail: a message already sitting in a
// trash folder would be deleted for good by another delete. The guard fails
// closed: when the folder record cannot say (no specialUse array), the
// folder is resolved via folders.query, and if trash membership still cannot
// be established the delete is refused.
async function assertTrashSafe(header) {
  let folder = header.folder || null;
  if (!trashDeterminable(folder) && header.folderId) {
    const resolved = await browser.folders.query({ id: header.folderId });
    if (resolved.length) folder = resolved[0];
  }
  if (trashDeterminable(folder) && inTrash(folder)) {
    throw new Error("message is already in the Trash — the proxy never deletes mail permanently");
  }
  if (!trashDeterminable(folder)) {
    throw new Error("cannot tell whether the message is in the Trash — refusing to delete");
  }
}

function slimFolder(folder) {
  return {
    id: folder.id,
    accountId: accountIdOf(folder),
    name: folder.name,
    path: folder.path,
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
    folder: message.folder.name,
    folderId: message.folder.id,
    accountId: accountIdOf(message.folder),
    size: message.size,
  };
}

// MessageId is an integer in the WebExtension API, while the REST path
// hands it over as a string — convert, and fail loudly on garbage.
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
    folders.find((f) => String(f.name ?? "").toLowerCase() === wanted || String(f.path ?? "").toLowerCase() === wanted);
  if (!match) throw new Error(`folder not found: ${params.folder}`);
  return match.id;
}
