// Persistent background script: keeps a long-poll loop against the local
// thunderbird-proxy, executes dispatched commands, and reports results.
// The proxy is the only thing this add-on talks to; if it is down we back
// off exponentially and keep retrying.
/* global browser */

const DEFAULTS = { proxyUrl: "http://127.0.0.1:8090", token: "" };

let settings = { ...DEFAULTS };
let backoffMs = 1000;

async function loadSettings() {
  settings = { ...DEFAULTS, ...(await browser.storage.local.get(DEFAULTS)) };
}

function api(path, options = {}) {
  return fetch(settings.proxyUrl + path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${settings.token}`,
      ...(options.headers || {}),
    },
  });
}

function setBadge(connected) {
  browser.browserAction.setBadgeText({ text: connected ? "on" : "off" });
  browser.browserAction.setBadgeBackgroundColor({ color: connected ? "#2e7d32" : "#c62828" });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function register() {
  const info = { addonVersion: browser.runtime.getManifest().version };
  try {
    info.thunderbird = (await browser.runtime.getBrowserInfo()).version;
  } catch {
    // getBrowserInfo may be unavailable — registration still succeeds.
  }
  const res = await api("/addon/hello", { method: "POST", body: JSON.stringify(info) });
  if (!res.ok) throw new Error(`hello failed: ${res.status}`);
}

async function execute(command) {
  const result = { id: command.id, ok: true };
  try {
    result.data = await ProxyCommands.run(command.command, command.params || {});
  } catch (error) {
    result.ok = false;
    result.error = String((error && error.message) || error);
  }
  const res = await api("/addon/result", { method: "POST", body: JSON.stringify(result) });
  if (!res.ok) console.warn(`result for ${command.id} rejected: ${res.status}`);
}

async function pollLoop() {
  for (;;) {
    try {
      await loadSettings();
      if (!settings.token) throw new Error("no token configured (options page)");
      await register();
      backoffMs = 1000;
      setBadge(true);
      for (;;) {
        const res = await api("/addon/poll");
        if (res.status === 204) continue;
        if (!res.ok) throw new Error(`poll failed: ${res.status}`);
        await execute(await res.json());
      }
    } catch (error) {
      setBadge(false);
      console.warn(`proxy bridge offline: ${error.message}; retrying in ${backoffMs}ms`);
      await sleep(backoffMs);
      backoffMs = Math.min(backoffMs * 2, 30000);
    }
  }
}

browser.storage.onChanged.addListener(() => {
  // A settings change restarts the loop so a new URL/token applies at once.
  loadSettings().then(() => {
    backoffMs = 1000;
  });
});

pollLoop();
