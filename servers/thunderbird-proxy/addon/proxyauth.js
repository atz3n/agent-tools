// Proxy response authentication helpers, shared by the background loop and
// the options page. The proxy signs every add-on-face response with
// HMAC-SHA256(secret, "<request nonce>\n<body>") in the X-Proxy-Proof
// header; verifying it before executing any command means an impostor
// listening on the proxy's port cannot forge work for us.
/* global crypto */

function randomNonce() {
  return [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// True when `proof` is a valid signature of `nonce + "\n" + body`.
async function proofValid(secret, nonce, body, proof) {
  if (!secret || !proof) return false;
  return constantTimeEqual(await hmacHex(secret, `${nonce}\n${body}`), proof);
}
