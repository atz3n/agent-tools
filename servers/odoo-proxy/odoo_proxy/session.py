#!/usr/bin/env python3
"""Odoo session management — login, cookie persistence, and RPC calls."""

from __future__ import annotations

import http.client
import json
import re
import time
from urllib.parse import urlencode, urlparse

from .config import SESSION_TIMEOUT, Config


class SessionExpiredError(RuntimeError):
    """Raised when the Odoo session has expired."""


class OdooSession:
    """Manages an authenticated Odoo session with cookie persistence."""

    def __init__(self, config: Config) -> None:
        self.config = config
        parsed = urlparse(config["url"])
        self.host: str = parsed.hostname or parsed.netloc
        self.port: int = parsed.port or (443 if parsed.scheme == "https" else 80)
        self.scheme: str = parsed.scheme or "https"
        self.base_path: str = parsed.path.rstrip("/")
        self._cookie: str | None = None
        self._last_login: float = 0.0

    # ------------------------------------------------------------------
    # Session lifecycle
    # ------------------------------------------------------------------

    def _is_expired(self) -> bool:
        """Check if session has timed out."""
        if not self._cookie:
            return True
        return (time.monotonic() - self._last_login) > SESSION_TIMEOUT

    def _ensure_session(self) -> None:
        """Ensure we have a valid session, logging in if needed."""
        if self._is_expired() or not self._cookie:
            self._login()

    def _reauthenticate(self) -> None:
        """Force re-authentication."""
        self._cookie = None
        self._login()

    # ------------------------------------------------------------------
    # Login (two-step Odoo flow)
    # ------------------------------------------------------------------

    def _login(self) -> None:
        """Perform the two-step Odoo login flow."""
        # Step 1: GET /web/login to get CSRF token
        conn = self._connection()
        try:
            conn.request("GET", f"{self.base_path}/web/login")
            resp = conn.getresponse()
            body = resp.read().decode("utf-8", errors="replace")
        finally:
            conn.close()

        match resp.status:
            case 200 | 302:
                pass
            case _:
                raise RuntimeError(f"Login step 1 failed: HTTP {resp.status}")

        token_match = re.search(r'name="csrf_token"\s+value="([^"]+)"', body)
        if not token_match:
            token_match = re.search(r'csrf_token:\s*"([^"]+)"', body)
        if not token_match:
            raise RuntimeError("Could not extract CSRF token from login page")

        csrf_token = token_match.group(1)

        # Extract initial session cookie from step 1 response
        initial_cookie = _extract_session_cookie(resp)

        # Step 2: POST /web/login with credentials (form body must be URL-encoded
        # so special characters in user/password/csrf don't corrupt the fields)
        conn = self._connection()
        post_body = urlencode(
            {
                "csrf_token": csrf_token,
                "login": self.config["user"],
                "password": self.config["password"],
            }
        )
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        if initial_cookie:
            headers["Cookie"] = initial_cookie

        try:
            conn.request("POST", f"{self.base_path}/web/login", body=post_body, headers=headers)
            resp = conn.getresponse()
        finally:
            conn.close()

        match resp.status:
            case 200 | 302 | 303:
                pass
            case _:
                raise RuntimeError(f"Login step 2 failed: HTTP {resp.status}")

        self._cookie = _extract_session_cookie(resp)

        if not self._cookie:
            raise RuntimeError("No session cookie received after login")

        self._last_login = time.monotonic()

    # ------------------------------------------------------------------
    # HTTP helpers
    # ------------------------------------------------------------------

    def _connection(self) -> http.client.HTTPSConnection | http.client.HTTPConnection:
        """Create an HTTP connection to the Odoo instance."""
        if self.scheme == "https":
            return http.client.HTTPSConnection(self.host, self.port, timeout=30)
        return http.client.HTTPConnection(self.host, self.port, timeout=30)

    def _call_odoo(self, path: str, body: bytes, headers: dict[str, str]) -> dict:
        """Send an HTTP POST to Odoo and return the parsed result dict.

        Raises SessionExpiredError on 403/302 so the caller can retry.
        """
        conn = self._connection()
        try:
            conn.request("POST", path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        finally:
            conn.close()

        match resp.status:
            case 403 | 302:
                raise SessionExpiredError(f"HTTP {resp.status}")
            case _:
                pass

        if not data:
            raise RuntimeError(f"Empty response from Odoo (HTTP {resp.status}, path={path})")

        try:
            # errors="replace": a non-UTF-8 upstream body (latin-1 gateway
            # error page etc.) must fail into the JSON error below — a clean
            # 502 — not escape the handler as a UnicodeDecodeError.
            result = json.loads(data.decode("utf-8", errors="replace"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"Non-JSON response from Odoo (HTTP {resp.status}, path={path}): "
                f"{data.decode('utf-8', errors='replace')[:200]}"
            ) from exc

        if "error" in result:
            raise RuntimeError(f"Odoo RPC error: {result['error']}")
        return result.get("result", {})

    # ------------------------------------------------------------------
    # RPC endpoints
    # ------------------------------------------------------------------

    def call_rpc(
        self,
        model: str,
        method: str,
        args: list | None = None,
        kwargs: dict | None = None,
    ) -> dict:
        """Call an Odoo RPC method and return the result dict.

        Handles session expiry by retrying once after re-auth.
        """
        payload = {
            "jsonrpc": "2.0",
            "method": "call",
            "params": {
                "model": model,
                "method": method,
                "args": args or [],
                "kwargs": kwargs or {},
            },
        }

        body = json.dumps(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Cookie": self._cookie or "",
        }
        path = f"{self.base_path}/web/dataset/call_kw"

        def _do() -> dict:
            self._ensure_session()
            headers["Cookie"] = self._cookie or ""
            return self._call_odoo(path, body, headers)

        try:
            return _do()
        except SessionExpiredError:
            self._reauthenticate()
            return _do()

    def get_messages(
        self,
        thread_id: int,
        thread_model: str = "project.task",
        limit: int = 30,
    ) -> dict:
        """Fetch messages for a thread via /mail/thread/messages."""
        payload = {
            "jsonrpc": "2.0",
            "method": "call",
            "params": {
                "thread_id": thread_id,
                "thread_model": thread_model,
                "limit": limit,
            },
        }

        body = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json", "Cookie": self._cookie or ""}
        path = f"{self.base_path}/mail/thread/messages"

        def _do() -> dict:
            self._ensure_session()
            headers["Cookie"] = self._cookie or ""
            return self._call_odoo(path, body, headers)

        try:
            return _do()
        except SessionExpiredError:
            self._reauthenticate()
            return _do()


    def post_message(
        self,
        thread_id: int,
        body: str,
        thread_model: str = "project.task",
        message_type: str = "comment",
        subtype_xmlid: str = "mail.mt_note",
    ) -> dict:
        """Post a note message to a thread via Odoo's /mail/message/post route.

        This is the route Odoo's own web client uses (captured live in
        spec/05-post-message.http). The generic /web/dataset/call_kw route
        cannot target a record for ``message_post`` — it invokes the method on
        an empty recordset, and ``body`` is message_post's first positional
        parameter, so passing the thread id in ``args`` collides with the
        ``body`` kwarg.
        """
        payload = {
            "jsonrpc": "2.0",
            "method": "call",
            "params": {
                "thread_id": thread_id,
                "thread_model": thread_model,
                "context": {
                    "lang": "en_GB",
                    "tz": "Europe/Berlin",
                },
                "post_data": {
                    "body": body,
                    "attachment_ids": [],
                    "attachment_tokens": [],
                    "canned_response_ids": [],
                    "message_type": message_type,
                    "partner_ids": [],
                    "subtype_xmlid": subtype_xmlid,
                    "partner_emails": [],
                    "partner_additional_values": {},
                },
            },
        }

        body_bytes = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json", "Cookie": self._cookie or ""}
        path = f"{self.base_path}/mail/message/post"

        def _do() -> dict:
            self._ensure_session()
            headers["Cookie"] = self._cookie or ""
            return self._call_odoo(path, body_bytes, headers)

        try:
            return _do()
        except SessionExpiredError:
            self._reauthenticate()
            return _do()


# ---------------------------------------------------------------------------
# Global session (lazy singleton)
# ---------------------------------------------------------------------------

_session: OdooSession | None = None
_session_config: Config | None = None


def get_session(config: Config) -> OdooSession:
    """Return the global OdooSession, re-creating it only when the config changes.

    Compares by value, not identity — callers may pass an equal dict on every
    request without forcing a re-login.
    """
    global _session, _session_config
    if _session is None or _session_config != config:
        _session_config = dict(config)
        _session = OdooSession(config)
    return _session


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _extract_session_cookie(resp: http.client.HTTPResponse) -> str:
    """Extract session_id cookie parts from a response.

    HTTP allows repeated Set-Cookie headers and Odoo front-ends may emit
    unrelated cookies before the session one, so every Set-Cookie header is
    scanned — not just the first.
    """
    headers = resp.msg.get_all("Set-Cookie") or []
    parts: list[str] = []
    for header in headers:
        for part in header.split(";"):
            part = part.strip()
            if part.startswith("session_id="):
                parts.append(part)
    return "; ".join(parts)
