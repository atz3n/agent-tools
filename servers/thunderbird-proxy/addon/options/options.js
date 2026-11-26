/* global browser */

const DEFAULTS = { proxyUrl: "http://localhost:8090", token: "" };

const $ = (id) => document.getElementById(id);

async function load() {
  const stored = await browser.storage.local.get(DEFAULTS);
  $("proxyUrl").value = stored.proxyUrl ?? DEFAULTS.proxyUrl;
  $("token").value = stored.token ?? DEFAULTS.token;
}

function show(message, ok) {
  const el = $("status");
  el.textContent = message;
  el.className = ok ? "ok" : "bad";
}

$("save").addEventListener("click", async () => {
  await browser.storage.local.set({
    proxyUrl: $("proxyUrl").value.trim() || DEFAULTS.proxyUrl,
    token: $("token").value.trim(),
  });
  show("Saved. The bridge reconnects automatically.", true);
});

$("test").addEventListener("click", async () => {
  const url = $("proxyUrl").value.trim() || DEFAULTS.proxyUrl;
  try {
    const res = await fetch(url + "/status", {
      headers: { Authorization: `Bearer ${$("token").value.trim()}` },
    });
    if (res.status === 401) return show("Reached the proxy, but the token was rejected.", false);
    const data = await res.json();
    show(res.ok ? `Proxy reachable. Add-on connected: ${data.connected}` : `Proxy returned ${res.status}.`, res.ok);
  } catch (error) {
    show(`Cannot reach ${url}: ${error.message}`, false);
  }
});

load();
