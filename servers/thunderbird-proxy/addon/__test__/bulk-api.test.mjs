// Unit tests for the mailBulk experiment API (bulk/api.js). The parent
// script is written for Thunderbird's addon_parent sandbox; it runs here in
// a vm context with ExtensionAPI and a stubbed message manager.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const source = readFileSync(new URL("../bulk/api.js", import.meta.url), "utf8");

function folder(name) {
  return {
    URL: `mailbox://${name}`,
    read: [],
    flagged: [],
    markMessagesRead(hdrs, v) { this.read.push(hdrs.map((h) => h.id).join(",") + "=" + v); },
    markMessagesFlagged(hdrs, v) { this.flagged.push(hdrs.map((h) => h.id).join(",") + "=" + v); },
  };
}

function loadApi(messages) {
  const context = createContext({
    ExtensionAPI: class { },
    Ci: {},
  });
  runInContext(source, context);
  const api = new (runInContext("mailBulk", context))({});
  const contextObj = { extension: { messageManager: { get: (id) => messages[id] ?? null } } };
  return api.getAPI(contextObj).mailBulk;
}

test("markMessages flags the whole batch per folder in one call each", async () => {
  const inbox = folder("INBOX");
  const news = folder("INBOX/News");
  const api = loadApi({
    7: { id: 7, folder: inbox },
    8: { id: 8, folder: inbox },
    9: { id: 9, folder: news },
  });
  const result = await api.markMessages({ messageIds: [7, 8, 9], read: true });
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { updated: 3, missing: [] });
  assert.deepEqual(inbox.read, ["7,8=true"]); // one set-level call, not two
  assert.deepEqual(news.read, ["9=true"]);
});

test("markMessages returns the unknown id in missing and flags nothing (fail closed)", async () => {
  const inbox = folder("INBOX");
  const api = loadApi({ 7: { id: 7, folder: inbox } });
  const result = await api.markMessages({ messageIds: [7, 99], read: true });
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { updated: 0, missing: [99] });
  assert.deepEqual(inbox.read, []); // nothing was flagged
});

test("markMessages applies read and flagged together, and either alone", async () => {
  const inbox = folder("INBOX");
  const api = loadApi({ 7: { id: 7, folder: inbox } });
  await api.markMessages({ messageIds: [7], read: false, flagged: true });
  assert.deepEqual(inbox.read, ["7=false"]);
  assert.deepEqual(inbox.flagged, ["7=true"]);
  await api.markMessages({ messageIds: [7], flagged: false });
  assert.equal(inbox.read.length, 1); // read untouched when not requested
});
