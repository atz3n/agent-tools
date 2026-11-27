// Unit tests for the add-on command dispatcher: node --test addon/__test__/.
// commands.js is a plain script (no modules), so it runs in a vm context
// with a stubbed `browser` and the handlers are read back out of it.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const source = readFileSync(new URL("../commands.js", import.meta.url), "utf8");

function load(stub) {
  const context = createContext({ browser: stub });
  runInContext(source, context);
  return runInContext("ProxyCommands", context);
}

test("accounts.list parses includeSubFolders as a boolean, not string-truthiness", async () => {
  const calls = [];
  const commands = load({ accounts: { list: async (deep) => { calls.push(deep); return []; } } });
  await commands.run("accounts.list", { includeSubFolders: "false" });
  await commands.run("accounts.list", { includeSubFolders: "true" });
  await commands.run("accounts.list", { includeSubFolders: true });
  await commands.run("accounts.list", {});
  assert.deepEqual(calls, [false, true, true, false]);
});

test("message.send omits empty cc/bcc arrays (only non-empty recipients are sent)", async () => {
  const sent = [];
  const commands = load({
    messages: { sendMessage: async (details) => { sent.push(details); return { messages: [] }; } },
  });
  await commands.run("message.send", { to: ["a@b.c"], cc: [], bcc: [], subject: "s", body: "t" });
  await commands.run("message.send", { to: ["a@b.c"], cc: ["c@d.e"], subject: "s", body: "t" });
  assert.deepEqual(sent[0].to, ["a@b.c"]);
  assert.equal("cc" in sent[0], false);
  assert.equal("bcc" in sent[0], false);
  assert.deepEqual(sent[1].cc, ["c@d.e"]);
});

test("message.draft omits empty cc/bcc arrays (saveMessage never sees cc: [])", async () => {
  let saved = null;
  const commands = load({
    messages: { saveMessage: async (details) => { saved = details; return { messages: [] }; } },
  });
  await commands.run("message.draft", { to: ["a@b.c"], cc: [], bcc: [], subject: "s", body: "t" });
  assert.deepEqual(saved.to, ["a@b.c"]);
  assert.equal("cc" in saved, false);
  assert.equal("bcc" in saved, false);
});

test("message.send compose fallback omits empty cc/bcc arrays too", async () => {
  let details = null;
  const commands = load({
    messages: {}, // no messages.sendMessage on this build — forces the compose fallback
    compose: {
      beginNew: async (_undefined, d) => { details = d; return { id: 1 }; },
      sendMessage: async () => {},
    },
  });
  await commands.run("message.send", { to: ["a@b.c"], cc: [], bcc: [], subject: "s", body: "t" });
  assert.deepEqual(details.to, ["a@b.c"]);
  assert.equal("cc" in details, false);
  assert.equal("bcc" in details, false);
});

test("message.update passes an empty tags array through (clears tags)", async () => {
  let updated = null;
  const commands = load({
    messages: { update: async (id, properties) => { updated = { id, properties }; } },
  });
  await commands.run("message.update", { message_id: "42", tags: [] });
  // Objects built inside the vm context carry that realm's prototypes —
  // round-trip through JSON before comparing.
  assert.deepEqual(JSON.parse(JSON.stringify(updated)), { id: 42, properties: { tags: [] } });
});

test("folders.create creates under the resolved parent folder", async () => {
  const calls = [];
  const commands = load({
    folders: {
      create: async (parentId, name) => { calls.push([parentId, name]); return { id: `${parentId}/News`, name }; },
      query: async () => [{ id: "acc1/INBOX", name: "Inbox", path: "/INBOX" }],
    },
  });
  await commands.run("folders.create", { folderId: "acc1", name: "Newsletter" });
  await commands.run("folders.create", { account: "acc1", folder: "INBOX", name: "Newsletter" });
  assert.deepEqual(calls, [["acc1", "Newsletter"], ["acc1/INBOX", "Newsletter"]]);
});

test("folder lookup prefers an exact name/path match over a case-insensitive one", async () => {
  const calls = [];
  const commands = load({
    folders: {
      create: async (parentId, name) => { calls.push(parentId); return { id: parentId, name }; },
      query: async () => [
        { id: "acc1/lo", name: "inbox", path: "/lo" },
        { id: "acc1/INBOX", name: "INBOX", path: "/INBOX" },
      ],
    },
  });
  await commands.run("folders.create", { account: "acc1", folder: "INBOX", name: "x" }); // exact name
  await commands.run("folders.create", { account: "acc1", folder: "/lo", name: "x" }); // exact path
  await commands.run("folders.create", { account: "acc1", folder: "Inbox", name: "x" }); // case-insensitive
  assert.deepEqual(calls, ["acc1/INBOX", "acc1/lo", "acc1/lo"]);
});

test("folders.update renames through browser.folders.rename", async () => {
  const calls = [];
  const commands = load({
    folders: {
      query: async () => [{ id: "acc1/News", accountId: "acc1", name: "News", path: "/News" }],
      rename: async (id, newName) => { calls.push([id, newName]); return { id, name: newName }; },
    },
  });
  const result = await commands.run("folders.update", { folder_id: "acc1/News", name: "Archive" });
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [["acc1/News", "Archive"]]);
  assert.equal(JSON.parse(JSON.stringify(result)).folder.name, "Archive");
});

test("folders.update refuses a rename onto an existing sibling (would hang Thunderbird)", async () => {
  let renamed = false;
  const commands = load({
    folders: {
      query: async () => [
        { id: "acc1/News", accountId: "acc1", name: "News", path: "/News" },
        { id: "acc1/Archive", accountId: "acc1", name: "Archive", path: "/Archive" },
        { id: "acc2/Archive", accountId: "acc2", name: "Archive", path: "/Archive" }, // other account, no clash
      ],
      rename: async () => { renamed = true; },
    },
  });
  await assert.rejects(() => commands.run("folders.update", { folder_id: "acc1/News", name: "Archive" }), /already exists/);
  assert.equal(renamed, false);
});

test("folders.delete refuses a folder that still holds messages", async () => {
  let deleted = false;
  const commands = load({
    folders: {
      getSubFolders: async () => [],
      query: async () => [{ id: "acc1/News" }],
      delete: async () => { deleted = true; },
    },
  });
  await assert.rejects(() => commands.run("folders.delete", { folder_id: "acc1/News" }), /not empty/);
  assert.equal(deleted, false);
});

test("folders.delete refuses a folder whose sub-sub-folder still holds messages", async () => {
  let deleted = false;
  const commands = load({
    folders: {
      getSubFolders: async () => [{ id: "acc1/News/Sub", subFolders: [{ id: "acc1/News/Sub/Leaf" }] }],
      query: async () => [{ id: "acc1/News/Sub/Leaf" }],
      delete: async () => { deleted = true; },
    },
  });
  await assert.rejects(() => commands.run("folders.delete", { folder_id: "acc1/News" }), /not empty/);
  assert.equal(deleted, false);
});

test("folders.delete removes an empty folder (non-empty folders elsewhere do not block it)", async () => {
  const deleted = [];
  const commands = load({
    folders: {
      getSubFolders: async () => [{ id: "acc1/News/Sub" }],
      query: async () => [{ id: "acc1/INBOX" }],
      delete: async (id) => { deleted.push(id); },
    },
  });
  const result = await commands.run("folders.delete", { folder_id: "acc1/News" });
  assert.deepEqual(deleted, ["acc1/News"]);
  assert.equal(result.deleted, true);
});

test("folders.delete turns Thunderbird's opaque IMAP failure into a named cause", async () => {
  const commands = load({
    folders: {
      getSubFolders: async () => [],
      query: async () => [],
      delete: async () => { throw new Error("folders.delete() failed for unknown reasons"); },
    },
  });
  await assert.rejects(() => commands.run("folders.delete", { folder_id: "acc1/x" }), /bug 2013929/);
});

test("message.delete moves to Trash and never sets deletePermanently", async () => {
  const calls = [];
  const commands = load({
    messages: {
      get: async () => ({ id: 7, folder: { id: "acc1/INBOX", specialUse: ["inbox"] } }),
      delete: async (ids, options) => { calls.push([ids, options]); },
    },
  });
  await commands.run("message.delete", { message_id: "7" });
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [[[7], { deletePermanently: false }]]);
});

test("message.delete refuses a message already in the Trash (would purge it)", async () => {
  let called = false;
  const commands = load({
    messages: {
      get: async () => ({ id: 7, folder: { id: "acc1/[Gmail]/Bin", specialUse: ["trash"] } }),
      delete: async () => { called = true; },
    },
  });
  await assert.rejects(() => commands.run("message.delete", { message_id: "7" }), /permanently/);
  assert.equal(called, false);
});

test("message.delete still honours the legacy folder type property", async () => {
  let called = false;
  const commands = load({
    messages: {
      get: async () => ({ id: 7, folder: { id: "acc1/Trash", type: "trash" } }), // pre-specialUse build
      delete: async () => { called = true; },
    },
  });
  await assert.rejects(() => commands.run("message.delete", { message_id: "7" }), /permanently/);
  assert.equal(called, false);
});
