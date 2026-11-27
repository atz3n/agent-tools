// Persistent background script: keeps a long-poll loop against the local
// thunderbird-proxy, executes dispatched commands, and reports results.
// The proxy is the only thing this add-on talks to; if it is down we back
// off exponentially and keep retrying. Every proxy response must carry a
// valid X-Proxy-Proof signature (see proxyauth.js) before we act on it.
/* global browser, randomNonce, proofValid */

const DEFAULTS = { proxyUrl: "http://127.0.0.1:8090", token: "", responseSecret: "" };

let settings = { ...DEFAULTS };
let backoffMs = 1000;
let restartRequested = false;

async function loadSettings() {
  settings = { ...DEFAULTS, ...(await browser.storage.local.get(DEFAULTS)) };
}

// Signed request to the proxy. Resolves to { res, json } once the response
// signature has been verified; throws on an unverifiable response, which
// the poll loop treats exactly like a disconnect.
async function api(path, options = {}) {
  const nonce = randomNonce();
  const res = await fetch(settings.proxyUrl + path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${settings.token}`,
      "X-Addon-Nonce": nonce,
      ...(options.headers || {}),
    },
  });
  const body = await res.arrayBuffer();
  const text = new TextDecoder().decode(body);
  if (!settings.responseSecret) throw new Error("no response secret configured (options page)");
  if (!(await proofValid(settings.responseSecret, nonce, text, res.headers.get("X-Proxy-Proof") || ""))) {
    throw new Error("proxy response signature invalid — refusing to trust the service on this port");
  }
  return { res, json: () => JSON.parse(text) };
}

function setBadge(connected) {
  browser.browserAction.setBadgeText({ text: connected ? "on" : "off" });
  browser.browserAction.setBadgeBackgroundColor({ color: connected ? "#2e7d32" : "#c62828" });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Backoff sleep in short ticks so a settings change wakes it early — saving
// a corrected URL/token on the options page retries immediately instead of
// waiting out the remaining backoff.
async function sleepBackoff(ms) {
  for (let waited = 0; waited < ms; waited += 500) {
    if (restartRequested) return;
    await sleep(Math.min(500, ms - waited));
  }
}

async function register() {
  const info = { addonVersion: browser.runtime.getManifest().version };
  try {
    info.thunderbird = (await browser.runtime.getBrowserInfo()).version;
  } catch {
    // getBrowserInfo may be unavailable — registration still succeeds.
  }
  const { res } = await api("/addon/hello", { method: "POST", body: JSON.stringify(info) });
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
  const { res } = await api("/addon/result", { method: "POST", body: JSON.stringify(result) });
  if (!res.ok) console.warn(`result for ${command.id} rejected: ${res.status}`);
}

async function pollLoop() {
  for (;;) {
    try {
      await loadSettings();
      restartRequested = false;
      if (!settings.token) throw new Error("no token configured (options page)");
      await register();
      backoffMs = 1000;
      setBadge(true);
      for (;;) {
        // A settings change (new URL/token/secret) re-registers via hello
        // instead of quietly polling a proxy that never saw a hello.
        if (restartRequested) break;
        const { res, json } = await api("/addon/poll");
        if (res.status === 204) continue;
        if (!res.ok) throw new Error(`poll failed: ${res.status}`);
        await execute(json());
      }
    } catch (error) {
      setBadge(false);
      console.warn(`proxy bridge offline: ${error.message}; retrying in ${backoffMs}ms`);
      await sleepBackoff(backoffMs);
      backoffMs = Math.min(backoffMs * 2, 30000);
    }
  }
}

browser.storage.onChanged.addListener(() => {
  // A settings change restarts the loop at the next poll boundary (or right
  // away, while backing off) so a new URL/token/secret re-registers via
  // hello — a URL change alone never errors, so nothing else would notice.
  restartRequested = true;
  backoffMs = 1000;
});

pollLoop();
