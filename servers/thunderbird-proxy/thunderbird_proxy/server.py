#!/usr/bin/env python3
"""Thunderbird mail proxy.

Exposes a small REST API on localhost (default 8090) for reading, searching,
organizing and sending email. The mail itself lives in Thunderbird, which a
MailExtension add-on drives; since an add-on cannot be called over HTTP, the
add-on dials out to this proxy, long-polls for commands, and reports results.
Agent requests block until their command comes back (or time out with 504).
"""

from __future__ import annotations

import hashlib
import hmac
import http.server
import json
import signal
import threading
from typing import Any

from . import config, whitelist
from .bridge import Bridge, BridgeError
from .config import BIND_HOST, PORT, logger

# Module-level singleton so tests can swap in a fresh bridge.
bridge = Bridge()

# ---------------------------------------------------------------------------
# Signal handler
# ---------------------------------------------------------------------------


def _shutdown(server: http.server.HTTPServer, signum: int, frame: object) -> None:
    """Gracefully shut down the HTTP server on SIGTERM/SIGINT.

    ``server.shutdown()`` waits for the ``serve_forever()`` loop to exit, so
    it must not run on the signal handler's own (main) thread — that
    deadlocks. Hand it to a short-lived thread instead.
    """
    threading.Thread(target=server.shutdown, daemon=True).start()


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Serve the agent face and the add-on face; reject everything else."""

    # Set per request in _handle: add-on-face responses are HMAC-signed for
    # the add-on to verify, keyed by the request nonce (replay-proof).
    _addon_signed = False
    _addon_nonce = ""

    def _reject(self, status: int, message: str, method: str, detail: str = "") -> None:
        logger.info(f"{method} {self.path} {status} from {self.client_address[0]}{detail}")
        self._respond(status, {"error": message}, body=method != "HEAD")

    def _respond(self, status: int, payload: Any, body: bool = True) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self._cors_header()
        self._proof_header(data)
        self.end_headers()
        if body:
            self.wfile.write(data)

    def _proof_header(self, data: bytes) -> None:
        if not self._addon_signed:
            return
        secret = config.THUNDERBIRD_ADDON_SECRET
        if not secret:
            return
        mac = hmac.new(secret.encode(), self._addon_nonce.encode() + b"\n" + data, hashlib.sha256)
        self.send_header("X-Proxy-Proof", mac.hexdigest())

    def _cors_header(self) -> None:
        """Echo the add-on's moz-extension origin — Thunderbird may apply
        CORS to the extension's fetches despite its host permission. The
        proof header must be listed explicitly or cross-origin JS cannot
        read it."""
        origin = self.headers.get("origin", "")
        if origin.startswith("moz-extension://"):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Expose-Headers", "X-Proxy-Proof")

    def _log_ok(self, method: str, status: int, detail: str) -> None:
        logger.info(f"{method} {self.path} {status} from {self.client_address[0]} {detail}")

    def _read_body(self, method: str) -> bytes | None:
        try:
            content_length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            content_length = -1  # malformed or negative — both rejected below
        if content_length < 0:
            self._reject(400, "invalid Content-Length header", method)
            return None
        return self.rfile.read(content_length)

    def _authorized(self, method: str, env_var: str) -> bool:
        """Mandatory per-face shared-secret gate (constant-time)."""
        token = getattr(config, env_var)
        if not token:
            self._reject(503, f"proxy not configured: {env_var} is required", method)
            return False
        if not hmac.compare_digest(self.headers.get("authorization", ""), f"Bearer {token}"):
            self._reject(401, "unauthorized", method)
            return False
        return True

    def _handle(self, method: str, body: bool) -> None:
        payload = self._read_body(method)
        if payload is None:
            return

        path = self.path.partition("?")[0]
        self._addon_signed = path.startswith("/addon/")
        self._addon_nonce = self.headers.get("x-addon-nonce", "") if self._addon_signed else ""
        gate = "THUNDERBIRD_ADDON_TOKEN" if self._addon_signed else "THUNDERBIRD_PROXY_TOKEN"
        if not self._authorized(method, gate):
            return

        if self._addon_signed:
            self._addon_face(method, path, payload, body)
            return

        matched = whitelist.match_endpoint(method, self.path)
        if matched is None:
            status = 405 if whitelist.path_known_any_method(self.path) else 404
            self._reject(status, "endpoint not allowed", method)
            return
        endpoint, params = matched
        if endpoint.command is None:
            self._respond(200, bridge.status(), body=body)
            self._log_ok(method, 200, "status")
            return

        if endpoint.command in ("message.send", "message.draft"):
            mail_params, error = whitelist.validate_mail_body(payload)
            if mail_params is None:
                self._reject(400, error, method)
                return
            params.update(mail_params)
            blocked = _blocked_recipients(params)
            if blocked:
                self._reject(403, f"recipient not allowed: {blocked}", method)
                return
        elif endpoint.command == "message.update":
            update_params, error = whitelist.validate_update_body(payload)
            if update_params is None:
                self._reject(400, error, method)
                return
            params.update(update_params)
        elif endpoint.command == "folders.create":
            folder_params, error = whitelist.validate_folder_create_body(payload)
            if folder_params is None:
                self._reject(400, error, method)
                return
            params.update(folder_params)
        elif endpoint.command == "folders.update":
            folder_params, error = whitelist.validate_folder_update_body(payload)
            if folder_params is None:
                self._reject(400, error, method)
                return
            params.update(folder_params)

        try:
            result = bridge.submit(endpoint.command, params)
        except BridgeError as exc:
            self._reject(exc.status, exc.message, method)
            return
        self._respond(200, result, body=body)
        self._log_ok(method, 200, f"command={endpoint.command}")

    # -- add-on face -----------------------------------------------------------

    def _addon_face(self, method: str, path: str, payload: bytes, body: bool) -> None:
        if (method, path) not in whitelist.ADDON_ENDPOINTS:
            status = 405 if path in {p for _, p in whitelist.ADDON_ENDPOINTS} else 404
            self._reject(status, "endpoint not allowed", method)
            return

        if path == "/addon/poll":
            command = bridge.poll()
            if command is None:
                self.send_response(204)
                self._cors_header()
                self._proof_header(b"")
                self.end_headers()
            else:
                self._respond(200, command)
            self._log_ok(method, 200 if command else 204, "poll")
            return

        if path == "/addon/status":
            self._respond(200, bridge.status())
            self._log_ok(method, 200, "addon status")
            return

        try:
            data = json.loads(payload) if payload else {}
        except ValueError:
            self._reject(400, "body must be valid JSON", method)
            return
        if not isinstance(data, dict):
            self._reject(400, "body must be a JSON object", method)
            return

        if path == "/addon/hello":
            bridge.hello(data)
            self._respond(200, {"ok": True})
            self._log_ok(method, 200, f"hello version={data.get('addonVersion', '?')}")
            return

        # /addon/result
        command_id = data.get("id")
        ok = bool(data.get("ok"))
        if not isinstance(command_id, str) or not bridge.report(command_id, ok, data.get("data"), data.get("error")):
            self._reject(404, "unknown command id", method)
            return
        self._respond(200, {"ok": True})
        self._log_ok(method, 200, f"result id={command_id} ok={ok}")

    # -- plumbing ------------------------------------------------------------

    def do_GET(self) -> None:
        self._handle("GET", body=True)

    def do_HEAD(self) -> None:
        # Enters _handle so HEAD mirrors the GET status without a body,
        # instead of BaseHTTP's 501.
        self._handle("HEAD", body=False)

    def do_POST(self) -> None:
        self._handle("POST", body=True)

    def do_PATCH(self) -> None:
        self._handle("PATCH", body=True)

    def do_DELETE(self) -> None:
        self._handle("DELETE", body=True)

    def do_OPTIONS(self) -> None:
        """CORS preflight from the add-on (any path, preflights carry no
        token and reveal nothing).

        Thunderbird has been seen to apply CORS to the add-on's fetches even
        with the host permission declared, so the bridge must not depend on
        the grant behaviour. Other origins keep the 501 default; the real
        request behind any preflight is fully token-gated.
        """
        origin = self.headers.get("origin", "")
        requested = self.headers.get("access-control-request-method", "?")
        if origin.startswith("moz-extension://"):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "GET, HEAD, POST, PATCH, DELETE")
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Addon-Nonce")
            self.send_header("Access-Control-Max-Age", "600")
            self.end_headers()
            self._log_ok("OPTIONS", 204, f"preflight {self.path.partition('?')[0]} as {requested} from {origin}")
            return
        self._reject(501, "method not implemented", "OPTIONS")

    def log_message(self, format: str, *args: object) -> None:
        """Override to silence the default access log (we use logger instead)."""
        pass


def _blocked_recipients(params: dict[str, Any]) -> str:
    """First recipient outside ALLOWED_SENDERS, or '' when the send is fine."""
    if not config.ALLOWED_SENDERS:
        return ""
    for recipient in whitelist.extract_recipients(params):
        if recipient not in config.ALLOWED_SENDERS:
            return recipient
    return ""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":  # pragma: no cover
    config.validate_config()

    server = http.server.ThreadingHTTPServer((BIND_HOST, PORT), ProxyHandler)
    server.daemon_threads = True  # in-flight long-polls must not block shutdown
    logger.info("thunderbird proxy listening on %s:%d", BIND_HOST, PORT)
    logger.info("  agent face: %d endpoints -> %s", len(whitelist.ENDPOINTS), ", ".join(sorted(whitelist.COMMANDS)))
    logger.info("  add-on face: %s", ", ".join(sorted(f"{m} {p}" for m, p in whitelist.ADDON_ENDPOINTS)))

    signal.signal(signal.SIGTERM, lambda s, f: _shutdown(server, s, f))
    signal.signal(signal.SIGINT, lambda s, f: _shutdown(server, s, f))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
