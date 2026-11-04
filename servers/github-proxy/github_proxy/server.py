#!/usr/bin/env python3
"""Minimal reverse proxy that exposes only GitHub Pull Request and Issue endpoints.

Forwards requests to https://api.github.com with Bearer auth from GITHUB_PERSONAL_ACCESS_TOKEN.
Non-PR/issue endpoints are rejected with 403.
"""

from __future__ import annotations

import http.client
import http.server
import signal
from urllib.parse import urlparse

from .config import PORT, TARGET, TOKEN, logger, validate_token
from .whitelist import _ALLOWED_PATHS, is_allowed_endpoint

# ---------------------------------------------------------------------------
# Signal handler
# ---------------------------------------------------------------------------


def _shutdown(server: http.server.HTTPServer, signum: int, frame: object) -> None:
    """Gracefully shut down the HTTP server on SIGTERM/SIGINT."""
    server.shutdown()


# ---------------------------------------------------------------------------
# Proxy handler
# ---------------------------------------------------------------------------

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Forward allowed PR/issue requests to GitHub; reject everything else."""

    def _proxy(self, method: str) -> None:
        raw_path = self.path
        path = raw_path.split("?")[0]  # strip query params for whitelist matching
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))

        if not is_allowed_endpoint(path):
            logger.info(f"{method} {raw_path} 403 from {self.client_address[0]}")
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"message":"endpoint not allowed"}')
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

        conn.request(method, raw_path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()

        logger.info(f"{method} {raw_path} {resp.status} from {self.client_address[0]}")

        self.send_response(resp.status)
        for h, v in resp.getheaders():
            if h.lower() not in ("transfer-encoding", "connection"):
                self.send_header(h, v)
        self.end_headers()
        self.wfile.write(data)
        conn.close()

    def do_GET(self) -> None:
        self._proxy("GET")

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

if __name__ == "__main__":
    validate_token()

    server = http.server.HTTPServer(("0.0.0.0", PORT), ProxyHandler)
    logger.info("PR/issue proxy listening on 127.0.0.1:%d -> %s", PORT, TARGET)
    for endpoint in _ALLOWED_PATHS:
        logger.info("  %s", endpoint)

    signal.signal(signal.SIGTERM, lambda s, f: _shutdown(server, s, f))
    signal.signal(signal.SIGINT, lambda s, f: _shutdown(server, s, f))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
