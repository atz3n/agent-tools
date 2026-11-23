#!/usr/bin/env python3
"""Minimal reverse proxy that exposes only GitHub Pull Request and Issue endpoints.

Forwards requests to https://api.github.com with Bearer auth from GITHUB_PERSONAL_ACCESS_TOKEN.
Non-PR/issue endpoints are rejected with 404.
"""

from __future__ import annotations

import http.client
import http.server
import signal
import threading
from urllib.parse import urlparse

from .config import BIND_HOST, PORT, TARGET, TOKEN, logger, validate_config
from .whitelist import ALLOWED_PATHS, is_allowed_endpoint, normalize_path

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
# Proxy handler
# ---------------------------------------------------------------------------

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Forward allowed PR/issue requests to GitHub; reject everything else."""

    def _proxy(self, method: str) -> None:
        raw_path = normalize_path(self.path)  # rewrite alias paths (e.g. requested-reviewers)
        path = raw_path.split("?")[0]  # strip query params for whitelist matching
        try:
            content_length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            content_length = -1  # malformed or negative — both rejected below
        if content_length < 0:
            logger.info(f"{method} {self.path} 400 from {self.client_address[0]}")
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"invalid Content-Length header"}')
            return
        body = self.rfile.read(content_length)

        if not is_allowed_endpoint(path):
            logger.info(f"{method} {raw_path} 404 from {self.client_address[0]}")
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"endpoint not allowed"}')
            return

        # Connect to GitHub
        parsed = urlparse(TARGET)
        hostname = parsed.hostname or "api.github.com"
        conn = http.client.HTTPSConnection(
            hostname, parsed.port or 443, timeout=30
        )

        # Merge headers (some headers like Accept appear twice with different MIME types)
        combine = {"accept"}
        headers: dict[str, str] = {}
        for key, value in self.headers.items():
            lk = key.lower()
            if lk in combine and lk in headers:
                headers[lk] = headers[lk] + ", " + value
            else:
                headers[lk] = value

        # Inject / override auth
        headers["authorization"] = f"Bearer {TOKEN}"
        headers["host"] = "api.github.com"
        headers.setdefault("user-agent", "pr-proxy/1.0")

        # Remove hop-by-hop headers
        for hop in ("connection", "keep-alive", "transfer-encoding"):
            headers.pop(hop, None)

        try:
            conn.request(method, raw_path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except (http.client.HTTPException, OSError) as exc:
            # Unreachable/slow GitHub — a clean 502 with one log line, never
            # a dropped connection with a traceback.
            logger.info(f"{method} {raw_path} 502 from {self.client_address[0]} ({exc})")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"upstream request failed"}')
            return
        finally:
            conn.close()

        logger.info(f"{method} {raw_path} {resp.status} from {self.client_address[0]}")

        self.send_response(resp.status)
        for h, v in resp.getheaders():
            if h.lower() not in ("transfer-encoding", "connection"):
                self.send_header(h, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        self._proxy("GET")

    def do_HEAD(self) -> None:
        self._proxy("HEAD")

    def do_POST(self) -> None:
        self._proxy("POST")

    def do_PATCH(self) -> None:
        self._proxy("PATCH")

    def do_PUT(self) -> None:
        self._proxy("PUT")

    def do_DELETE(self) -> None:
        self._proxy("DELETE")

    def log_message(self, format: str, *args: object) -> None:
        """Override to silence the default access log (we use logger instead)."""
        pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":  # pragma: no cover
    validate_config()

    server = http.server.ThreadingHTTPServer((BIND_HOST, PORT), ProxyHandler)
    server.daemon_threads = True  # in-flight requests must not block shutdown
    logger.info("PR/issue proxy listening on %s:%d -> %s", BIND_HOST, PORT, TARGET)
    for endpoint in ALLOWED_PATHS:
        logger.info("  %s", endpoint)

    signal.signal(signal.SIGTERM, lambda s, f: _shutdown(server, s, f))
    signal.signal(signal.SIGINT, lambda s, f: _shutdown(server, s, f))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
