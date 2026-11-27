#!/usr/bin/env python3
"""Endpoint whitelist and command mapping for the Thunderbird proxy.

The proxy has two faces. The *agent face* is a small REST API; each
whitelisted (method, path) pattern maps to exactly one command name from a
closed set, which is what the Thunderbird add-on is allowed to execute.
The *add-on face* is the fixed trio /addon/hello, /addon/poll, /addon/result.
Nothing else is routable — unknown paths 404, a known path with the wrong
method 405.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import parse_qs, unquote

# Message ids are opaque Thunderbird strings (base64-ish). They may contain
# '/' when raw, so callers must percent-encode; the pattern accepts literal
# id-safe characters plus %XX escapes, and the value is unquoted after
# matching — routing never sees a decoded '/'.
_MESSAGE_ID = r"(?:[A-Za-z0-9_\-]|%[0-9A-Fa-f]{2})+"


@dataclass(frozen=True)
class Endpoint:
    """One whitelisted agent-face route."""

    method: str
    pattern: re.Pattern[str]
    command: str | None  # None = served by the proxy itself (no add-on round-trip)
    path_params: tuple[str, ...] = ()
    query_params: tuple[str, ...] = field(default=())


def _endpoint(
    method: str,
    pattern: str,
    command: str | None,
    *,
    path_params: tuple[str, ...] = (),
    query: tuple[str, ...] = (),
) -> Endpoint:
    return Endpoint(method, re.compile(pattern), command, path_params, query)


# ---------------------------------------------------------------------------
# Agent-face table (order matters: literal /mail/* paths before /mail/{id})
# ---------------------------------------------------------------------------

ENDPOINTS: tuple[Endpoint, ...] = (
    _endpoint("GET", r"^/status$", None),
    _endpoint("GET", r"^/accounts$", "accounts.list", query=("includeSubFolders",)),
    _endpoint("GET", r"^/identities$", "identities.list", query=("account",)),
    _endpoint("GET", r"^/folders$", "folders.list", query=("account",)),
    _endpoint("GET", r"^/mail/list$", "messages.list", query=("folderId", "account", "folder", "limit", "offset")),
    (
        _endpoint(
            "GET", r"^/mail/search$", "messages.search",
            query=("subject", "body", "author", "to", "unread", "folderId", "account", "folder"),
        )
    ),
    _endpoint("POST", r"^/mail/send$", "message.send"),
    _endpoint("POST", r"^/mail/draft$", "message.draft"),
    _endpoint("GET", rf"^/mail/(?P<message_id>{_MESSAGE_ID})$", "message.get", path_params=("message_id",)),
    _endpoint("PATCH", rf"^/mail/(?P<message_id>{_MESSAGE_ID})$", "message.update", path_params=("message_id",)),
    _endpoint("DELETE", rf"^/mail/(?P<message_id>{_MESSAGE_ID})$", "message.delete", path_params=("message_id",)),
)

# Closed command set — derived, so a command can never be whitelisted here and
# missed by the add-on's dispatcher (or vice versa) without failing a test.
COMMANDS: frozenset[str] = frozenset(e.command for e in ENDPOINTS if e.command)

# Add-on face: exact (method, path) pairs, handled before the agent table.
ADDON_ENDPOINTS: frozenset[tuple[str, str]] = frozenset(
    {("POST", "/addon/hello"), ("GET", "/addon/poll"), ("POST", "/addon/result")}
)


# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------


def match_endpoint(method: str, path: str) -> tuple[Endpoint, dict[str, Any]] | None:
    """Match a request path against the agent-face table.

    Returns (endpoint, params) where params merges whitelisted query
    parameters with unquoted path captures, or None when nothing matches.
    HEAD mirrors GET.
    """
    if method == "HEAD":
        method = "GET"
    clean_path, sep, query = path.partition("?")
    for endpoint in ENDPOINTS:
        match = endpoint.pattern.match(clean_path)
        if not match or endpoint.method != method:
            continue
        params: dict[str, Any] = {}
        for name in endpoint.path_params:
            params[name] = unquote(match.group(name))
        if sep and query:
            for key, values in parse_qs(query, keep_blank_values=False).items():
                if key in endpoint.query_params and values:
                    params[key] = values[0]
        return endpoint, params
    return None


def path_known_any_method(path: str) -> bool:
    """True when the path matches some endpoint (for the 404-vs-405 choice)."""
    clean_path = path.partition("?")[0]
    return any(e.pattern.match(clean_path) for e in ENDPOINTS)


# ---------------------------------------------------------------------------
# Body policy for send/draft/update
# ---------------------------------------------------------------------------


def _recipient_list(value: object, field: str, item_label: str = "strings") -> str:
    """Error message when value is not a non-empty list of non-empty strings."""
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v.strip() for v in value):
        return f"{field} must be a non-empty array of {item_label}"
    return ""


def validate_mail_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse and police a message.send / message.draft JSON body.

    Returns (params, "") on success, (None, "<field> ...") naming the first
    offending field otherwise.
    """
    try:
        payload = json.loads(body)
    except ValueError:
        return None, "body must be valid JSON"
    if not isinstance(payload, dict):
        return None, "body must be a JSON object"
    for list_field in ("to", "cc", "bcc"):
        if list_field in payload:
            error = _recipient_list(payload[list_field], list_field)
            if error:
                return None, error
    if not payload.get("to"):
        return None, "to is required"
    subject = payload.get("subject")
    if not isinstance(subject, str) or not subject.strip():
        return None, "subject is required and must be a non-empty string"
    body_text = payload.get("body")
    if not isinstance(body_text, str):
        return None, "body is required and must be a string"
    params: dict[str, Any] = {
        "to": payload["to"],
        "subject": subject,
        "plainTextBody": body_text,
        "isPlainText": True,
    }
    for optional in ("cc", "bcc"):
        if optional in payload:
            params[optional] = payload[optional]
    if "identityId" in payload:
        if not isinstance(payload["identityId"], str):
            return None, "identityId must be a string"
        params["identityId"] = payload["identityId"]
    html = payload.get("html")
    if html is not None:
        if not isinstance(html, str):
            return None, "html must be a string when present"
        params["plainTextBody"] = None
        params["body"] = html
        params["isPlainText"] = False
    return params, ""


UPDATE_KEYS = frozenset({"read", "starred", "tags", "moveTo"})


def validate_update_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse a message.update PATCH body: subset of read/starred/tags/moveTo."""
    try:
        payload = json.loads(body)
    except ValueError:
        return None, "body must be valid JSON"
    if not isinstance(payload, dict) or not payload:
        return None, "body must be a non-empty JSON object"
    unknown = set(payload) - UPDATE_KEYS
    if unknown:
        return None, f"unsupported field: {sorted(unknown)[0]} (allowed: {', '.join(sorted(UPDATE_KEYS))})"
    if "read" in payload and not isinstance(payload["read"], bool):
        return None, "read must be a boolean"
    if "starred" in payload and not isinstance(payload["starred"], bool):
        return None, "starred must be a boolean"
    if "tags" in payload:
        error = _recipient_list(payload["tags"], "tags", "tag names")
        if error:
            return None, error
    if "moveTo" in payload and not isinstance(payload["moveTo"], str):
        return None, "moveTo must be a folder id string"
    params: dict[str, Any] = dict(payload)
    if "starred" in params:
        params["flagged"] = params.pop("starred")
    return params, ""


def extract_recipients(params: dict[str, Any]) -> list[str]:
    """All recipient addresses of a send/draft command, lowercased."""
    recipients: list[str] = []
    for key in ("to", "cc", "bcc"):
        value = params.get(key)
        if isinstance(value, list):
            recipients.extend(str(v).strip().lower() for v in value)
    return recipients
