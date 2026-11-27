/* global ExtensionAPI, Ci */
// Experiment API parent script — runs in the chrome-privileged addon_parent
// sandbox, unlike the sandboxed background script. This is the bridge's only
// privileged code: it exposes exactly one operation (bulk read/flag) built
// from two fixed folder methods (markMessagesRead/markMessagesFlagged) that
// Thunderbird's own UI uses: ids are grouped per folder and each folder gets
// one set-level call instead of one WebExtension round-trip per message.
// Nothing else in the bridge steps outside the permission-gated WebExtension
// APIs.

var mailBulk = class extends ExtensionAPI {
  getAPI(context) {
    return {
      mailBulk: {
        // Resolves ids and flags in one pass, returning { updated, missing }
        // instead of throwing: any error thrown here is sanitized before it
        // reaches the sandboxed caller, so the caller turns a non-empty
        // `missing` into a readable error the agent actually sees.
        async markMessages(details) {
          // The extension's own message manager resolves the WebExtension
          // message ids (session-scoped, tracked in memory) to live headers —
          // the exact same lookup browser.messages.update does.
          const { messageManager } = context.extension;
          const byFolder = new Map();
          const missing = [];
          for (const id of details.messageIds) {
            const hdr = messageManager.get(id);
            if (!hdr) {
              missing.push(id);
              continue;
            }
            // Group by folder identity so each folder gets one set-level
            // call; headers carry their folder, so no id reconstruction.
            const key = hdr.folder.URL;
            if (!byFolder.has(key)) byFolder.set(key, { folder: hdr.folder, headers: [] });
            byFolder.get(key).headers.push(hdr);
          }
          // Fail closed: an unknown id means the caller's view is stale, so
          // nothing is flagged rather than a partial batch.
          if (missing.length) return { updated: 0, missing };
          for (const { folder, headers } of byFolder.values()) {
            if (details.read !== undefined) folder.markMessagesRead(headers, Boolean(details.read));
            if (details.flagged !== undefined) folder.markMessagesFlagged(headers, Boolean(details.flagged));
          }
          return { updated: details.messageIds.length, missing: [] };
        },
      },
    };
  }
};
