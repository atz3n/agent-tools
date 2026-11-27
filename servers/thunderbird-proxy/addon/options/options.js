/* global browser, randomNonce, proofValid */

const DEFAULTS = { proxyUrl: "http://127.0.0.1:8090", token: "", responseSecret: "", commandTimeoutSec: 60 };
const TIMEOUT_LIMITS = { min: 5, max: 600 };

const $ = (id) => document.getElementById(id);

async function load() {
  const stored = await browser.storage.local.get(DEFAULTS);
  $("proxyUrl").value = stored.proxyUrl ?? DEFAULTS.proxyUrl;
  $("token").value = stored.token ?? DEFAULTS.token;
  $("responseSecret").value = stored.responseSecret ?? DEFAULTS.responseSecret;
  $("commandTimeoutSec").value = stored.commandTimeoutSec ?? "";
}

function show(message, ok) {
  const el = $("status");
  el.textContent = message;
  el.className = ok ? "ok" : "bad";
}

$("save").addEventListener("click", async () => {
  const raw = $("commandTimeoutSec").value.trim();
  const sec = raw === "" ? DEFAULTS.commandTimeoutSec : Number(raw);
  if (!Number.isInteger(sec) || sec < TIMEOUT_LIMITS.min || sec > TIMEOUT_LIMITS.max) {
    return show(`Command timeout must be a whole number of seconds between ${TIMEOUT_LIMITS.min} and ${TIMEOUT_LIMITS.max}.`, false);
  }
  await browser.storage.local.set({
    proxyUrl: $("proxyUrl").value.trim() || DEFAULTS.proxyUrl,
    token: $("token").value.trim(),
    responseSecret: $("responseSecret").value.trim(),
    commandTimeoutSec: sec,
  });
  show("Saved. The bridge reconnects automatically.", true);
});

$("test").addEventListener("click", async () => {
  const url = $("proxyUrl").value.trim() || DEFAULTS.proxyUrl;
  const nonce = randomNonce();
  try {
    const res = await fetch(`${url}/addon/status`, {
      headers: { Authorization: `Bearer ${$("token").value.trim()}`, "X-Addon-Nonce": nonce },
    });
    const text = await res.text();
    if (!(await proofValid($("responseSecret").value.trim(), nonce, text, res.headers.get("X-Proxy-Proof") || ""))) {
      return show("Reached a service, but its response signature is wrong — not your proxy, or the secret differs.", false);
    }
    if (res.status === 401) return show("Reached the proxy, but the add-on token was rejected.", false);
    const data = JSON.parse(text);
    show(res.ok ? `Proxy reachable and signed. Add-on connected: ${data.connected}` : `Proxy returned ${res.status}.`, res.ok);
  } catch (error) {
    show(`Cannot reach ${url}: ${error.message}`, false);
  }
});

load();
