#!/usr/bin/env python3
"""Credential-injecting reverse proxy for LLM inference providers.

Exposes one host:port (default 8089) with one path prefix per provider. The
proxy injects each provider's credentials internally, enforces a per-route
endpoint whitelist and an optional model allowlist, and passes the wire
format through untouched — SSE streams are byte-copied unbuffered so
token streaming reaches the client exactly as the provider sent it.
"""

from __future__ import annotations

import hmac
import http.client
import http.server
import json
import signal
import socket
import threading
from urllib.parse import urlparse

from . import config
from .config import BIND_HOST, PORT, logger
from .whitelist import (
    ROUTES,
    Route,
    extract_model,
    is_allowed,
    is_model_allowed,
    path_allowed_any_method,
    resolve_route,
    route_enabled,
)

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
# Helpers
# ---------------------------------------------------------------------------


def _auth_for(route_name: str) -> str | None:
    """Return the Authorization header value to inject for a route (None = strip)."""
    if route_name == "openrouter":
        return f"Bearer {config.OPENROUTER_API_KEY}"
    return None


def _usage_suffix(data: bytes) -> str:
    """Extract token usage from a JSON completion response for logging.

    Reads both dialects' key pairs: OpenAI (prompt_tokens/completion_tokens)
    and Anthropic-Messages (input_tokens/output_tokens).
    """
    try:
        payload = json.loads(data)
        usage = payload.get("usage") or {}
    except (ValueError, AttributeError):
        return ""
    if not isinstance(usage, dict) or not usage:
        return ""
    prompt = usage.get("prompt_tokens", usage.get("input_tokens", "?"))
    completion = usage.get("completion_tokens", usage.get("output_tokens", "?"))
    return f" tokens={prompt}+{completion}"


# ---------------------------------------------------------------------------
# Proxy handler
# ---------------------------------------------------------------------------


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Forward allowed inference requests to the routed provider; reject the rest."""

    # HTTP/1.0 (the default): after a streamed response with no Content-Length
    # or Transfer-Encoding, closing the connection is what signals end-of-body.
    # ThreadingHTTPServer keeps concurrent sessions independent.

    def _reject(self, status: int, message: str, method: str, detail: str = "") -> None:
        logger.info(f"{method} {self.path} {status} from {self.client_address[0]}{detail}")
        payload = json.dumps({"error": message}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _proxy(self, method: str) -> None:
        try:
            content_length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            content_length = -1  # malformed or negative — both rejected below
        if content_length < 0:
            self._reject(400, "invalid Content-Length header", method)
            return
        body = self.rfile.read(content_length)

        resolved = resolve_route(self.path)
        if resolved is None:
            self._reject(404, "not found", method)
            return
        name, route, path = resolved

        if not route_enabled(name):
            self._reject(404, "route not configured", method)
            return

        # Optional shared-secret gate so other host processes can't ride the proxy.
        if config.LLM_PROXY_TOKEN:
            if not hmac.compare_digest(self.headers.get("authorization", ""), f"Bearer {config.LLM_PROXY_TOKEN}"):
                self._reject(401, "unauthorized", method)
                return

        clean_path = path.split("?")[0]
        if not is_allowed(route, method, clean_path):
            status = 405 if path_allowed_any_method(route, clean_path) else 404
            self._reject(status, "endpoint not allowed", method)
            return

        model: str | None = None
        if method == "POST" and (clean_path.endswith("/chat/completions") or clean_path.endswith("/messages")):
            # Both completion dialects carry a "model" field — the allowlist
            # polices both, otherwise /v1/messages would be a silent bypass.
            model = extract_model(body)
            if config.ALLOWED_MODELS and model is None:
                # Strict gate: with an allowlist configured, a body without a
                # parsable model must not slip past the check.
                self._reject(400, "model field required when ALLOWED_MODELS is set", method)
                return
            if not is_model_allowed(model):
                self._reject(403, f"model not allowed: {model}", method)
                return

        self._forward(name, method, route, path, body, model)

    def _forward(
        self,
        name: str,
        method: str,
        route: Route,
        path: str,
        body: bytes,
        model: str | None,
    ) -> None:
        parsed = urlparse(route.target)
        hostname = parsed.hostname or "localhost"
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        if parsed.scheme == "https":
            conn: http.client.HTTPConnection = http.client.HTTPSConnection(
                hostname, port, timeout=config.UPSTREAM_TIMEOUT
            )
        else:
            conn = http.client.HTTPConnection(hostname, port, timeout=config.UPSTREAM_TIMEOUT)

        # Merge client headers, then own the credential and hop-by-hop headers.
        headers: dict[str, str] = {}
        for key, value in self.headers.items():
            lk = key.lower()
            if lk in ("connection", "keep-alive", "transfer-encoding", "authorization", "host"):
                continue
            headers.setdefault(lk, value)
        headers["host"] = hostname if parsed.port is None else f"{hostname}:{parsed.port}"
        headers.setdefault("user-agent", "llm-proxy/1.0")
        auth = _auth_for(name)
        if auth:
            headers["authorization"] = auth

        headers_sent = False
        try:
            conn.request(method, path, body=body or None, headers=headers)
            resp = conn.getresponse()

            self.send_response(resp.status)
            for h, v in resp.getheaders():
                if h.lower() in ("transfer-encoding", "connection"):
                    continue
                self.send_header(h, v)
            self.end_headers()
            headers_sent = True

            content_type = (resp.getheader("content-type") or "").lower()
            detail = f"{method} {self.path} {resp.status} from {self.client_address[0]}"
            if "text/event-stream" in content_type:
                self._copy_stream(resp)
                detail += " stream"
            else:
                data = resp.read()
                self.wfile.write(data)
                detail += _usage_suffix(data)
            if model:
                detail += f" model={model}"
            logger.info(detail)
        except (BrokenPipeError, ConnectionResetError):
            # Client hung up mid-stream — normal when a session is interrupted.
            logger.info(f"{method} {self.path} client-abort from {self.client_address[0]}")
        except (http.client.HTTPException, socket.timeout, TimeoutError, OSError) as exc:
            # One log line per request: before the headers go out, _reject's
            # own line carries the failure (with the exception as detail);
            # after them, _reject cannot run, so log the 502 line here.
            if headers_sent:
                logger.info(f"{method} {self.path} 502 from {self.client_address[0]} ({exc})")
            else:
                try:
                    self._reject(502, "upstream request failed", method, detail=f" ({exc})")
                except OSError:
                    pass
        finally:
            conn.close()

    def _copy_stream(self, resp: http.client.HTTPResponse) -> None:
        """Byte-copy an upstream SSE stream to the client, flushing per chunk."""
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

    def do_GET(self) -> None:
        self._proxy("GET")

    def do_HEAD(self) -> None:
        # Enters _proxy so HEAD gets the same 404/405 + flat error + log
        # line as any other method instead of BaseHTTP's 501.
        self._proxy("HEAD")

    def do_POST(self) -> None:
        self._proxy("POST")

    def do_PUT(self) -> None:
        self._proxy("PUT")

    def do_PATCH(self) -> None:
        self._proxy("PATCH")

    def do_DELETE(self) -> None:
        self._proxy("DELETE")

    def log_message(self, format: str, *args: object) -> None:
        """Override to silence the default access log (we use logger instead)."""
        pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":  # pragma: no cover
    config.validate_config()

    server = http.server.ThreadingHTTPServer((BIND_HOST, PORT), ProxyHandler)
    server.daemon_threads = True  # in-flight streams must not block shutdown
    logger.info("LLM proxy listening on %s:%d", BIND_HOST, PORT)
    for route_name, route in ROUTES.items():
        state = "enabled" if route_enabled(route_name) else "DISABLED (missing credentials)"
        logger.info("  %s -> %s [%s]", route.prefix, route.target, state)
        for method, pattern in route.allowed:
            logger.info("    %s %s", method, pattern.pattern)

    signal.signal(signal.SIGTERM, lambda s, f: _shutdown(server, s, f))
    signal.signal(signal.SIGINT, lambda s, f: _shutdown(server, s, f))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
