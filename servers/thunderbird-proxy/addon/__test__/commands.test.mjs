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
