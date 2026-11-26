// Command handlers executed on behalf of the thunderbird-proxy.
// The proxy only ever dispatches names from its closed command set; anything
// else is refused here too, so the wire can never drive arbitrary code.
/* global browser */

const ProxyCommands = {
  handlers: {
    async "accounts.list"(params) {
      const accounts = await browser.accounts.list(Boolean(params.includeSubFolders));
      return { accounts: accounts.map(slimAccount) };
    },

    async "folders.list"(params) {
      if (!params.account) throw new Error("account is required");
      const folders = await browser.folders.query({ accountId: params.account });
      return { folders: folders.map(slimFolder) };
    },

    async "messages.list"(params) {
      const folderId = await resolveFolderId(params);
      const limit = clampCount(params.limit, 25, 200);
      const offset = clampCount(params.offset, 0, 100000);
      let page = await browser.messages.list(folderId, { maxCount: Math.min(limit + offset, 200) });
      let messages = page.messages;
      while (messages.length < offset + limit && page.nextOffset != null) {
        page = await browser.messages.continueList(page.id);
        messages = messages.concat(page.messages);
      }
      return { messages: messages.slice(offset, offset + limit).map(slimMessage) };
    },

    async "messages.search"(params) {
      const queryInfo = {};
      for (const key of ["subject", "body", "author"]) {
        if (params[key]) queryInfo[key] = params[key];
      }
      if (!Object.keys(queryInfo).length) throw new Error("at least one of subject, body, author is required");
      const folderId = params.folderId || params.folder || params.account ? await resolveFolderId(params, true) : null;
      if (folderId) queryInfo.folderIds = [folderId];
      const page = await browser.messages.query(queryInfo);
      return { messages: page.messages.map(slimMessage) };
    },

    async "message.get"(params) {
      const header = await browser.messages.get(params.message_id);
      const full = await browser.messages.getFull(params.message_id);
      return { header: slimMessage(header), parts: full.parts };
    },

    async "message.send"(params) {
      const message = await browser.messages.sendMessage(buildOutgoing(params), { mode: "sendNow" });
      return { sent: true, message: slimMessage(message) };
    },

    async "message.draft"(params) {
      const message = await browser.messages.saveMessage(buildOutgoing(params));
      return { draft: true, message: slimMessage(message) };
    },

    async "message.update"(params) {
      const properties = {};
      for (const key of ["read", "flagged", "tags"]) {
        if (params[key] !== undefined) properties[key] = params[key];
      }
      if (Object.keys(properties).length) await browser.messages.update(params.message_id, properties);
      if (params.moveTo) await browser.messages.move([params.message_id], params.moveTo);
      return { updated: true };
    },

    async "message.delete"(params) {
      await browser.messages.delete([params.message_id]);
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
    size: message.size,
  };
}

function buildOutgoing(params) {
  const details = { subject: params.subject, identityId: params.identityId };
  for (const key of ["to", "cc", "bcc"]) {
    if (params[key]) details[key] = params[key];
  }
  if (params.isPlainText === false) {
    details.body = params.body;
    details.isPlainText = false;
  } else {
    details.plainTextBody = params.plainTextBody ?? params.body;
    details.isPlainText = true;
  }
  return details;
}

function clampCount(raw, fallback, max) {
  const value = Number.parseInt(raw, 10);
  if (Number.isNaN(value) || value < 0) return fallback;
  return Math.min(value, max);
}

// Resolve folderId directly, or an `account` + `folder` (name or path) pair,
// or just `folder` (a raw folder id). Returns null when nothing was asked for.
async function resolveFolderId(params, optional = false) {
  if (params.folderId) return params.folderId;
  if (!params.folder) {
    if (params.account) throw new Error("folder is required when account is given");
    if (optional) return null;
    throw new Error("folderId (or account + folder) is required");
  }
  if (!params.account) return params.folder; // raw folder id in `folder`
  const folders = await browser.folders.query({ accountId: params.account });
  const match = folders.find((f) => f.name === params.folder || f.path === params.folder);
  if (!match) throw new Error(`folder not found: ${params.folder}`);
  return match.id;
}
