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
_MESSAGE_ID = r"\d+"

# Thunderbird folder ids commonly contain '/' (IMAP ids look like
# "account3/INBOX/News"), so callers must percent-encode it; the pattern
# refuses a literal '/', so routing never sees a decoded separator.
_FOLDER_ID = r"[^/?]+"


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
    _endpoint("POST", r"^/folders$", "folders.create"),
    _endpoint("POST", r"^/folders/mark-read$", "folders.markRead"),
    _endpoint(
        "PATCH", rf"^/folders/(?P<folder_id>{_FOLDER_ID})$", "folders.update", path_params=("folder_id",)
    ),
    _endpoint(
        "DELETE", rf"^/folders/(?P<folder_id>{_FOLDER_ID})$", "folders.delete", path_params=("folder_id",)
    ),
    _endpoint("GET", r"^/mail/list$", "messages.list", query=("folderId", "account", "folder", "limit", "offset")),
    (
        _endpoint(
            "GET", r"^/mail/search$", "messages.search",
            query=("subject", "body", "author", "to", "unread", "folderId", "account", "folder"),
        )
    ),
    _endpoint("POST", r"^/mail/send$", "message.send"),
    _endpoint("POST", r"^/mail/draft$", "message.draft"),
    _endpoint("POST", r"^/mail/move$", "messages.move"),
    _endpoint("POST", r"^/mail/mark$", "messages.mark"),
    _endpoint("POST", r"^/mail/trash$", "messages.trash"),
    _endpoint("GET", rf"^/mail/(?P<message_id>{_MESSAGE_ID})$", "message.get", path_params=("message_id",)),
    _endpoint("PATCH", rf"^/mail/(?P<message_id>{_MESSAGE_ID})$", "message.update", path_params=("message_id",)),
    _endpoint("DELETE", rf"^/mail/(?P<message_id>{_MESSAGE_ID})$", "message.delete", path_params=("message_id",)),
)

# Closed command set — derived, so a command can never be whitelisted here and
# missed by the add-on's dispatcher (or vice versa) without failing a test.
COMMANDS: frozenset[str] = frozenset(e.command for e in ENDPOINTS if e.command)

# Add-on face: exact (method, path) pairs, handled before the agent table.
# /addon/status is the add-on's own health probe (options page "Test
# connection") — the agent-face /status needs the agent token, which the
# add-on no longer holds.
ADDON_ENDPOINTS: frozenset[tuple[str, str]] = frozenset(
    {("POST", "/addon/hello"), ("GET", "/addon/poll"), ("POST", "/addon/result"), ("GET", "/addon/status")}
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


def _recipient_list(value: object, field: str, item_label: str = "strings", allow_empty: bool = False) -> str:
    """Error message when value is not a list of non-empty strings.

    An empty list passes only when allow_empty (cc/bcc, tags) — clearing
    them with [] is a valid request; 'to' always needs at least one address.
    """
    if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
        return f"{field} must be {'an' if allow_empty else 'a non-empty'} array of {item_label}"
    if not value and not allow_empty:
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
            error = _recipient_list(payload[list_field], list_field, allow_empty=list_field != "to")
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


UPDATE_KEYS = frozenset({"read", "starred", "tags", "moveTo", "junk"})


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
    if "moveTo" in payload and (not isinstance(payload["moveTo"], str) or not payload["moveTo"].strip()):
        return None, "moveTo must be a non-empty folder id string"
    if "junk" in payload and not isinstance(payload["junk"], bool):
        return None, "junk must be a boolean"
    params, error = _flag_params(payload)
    if params is None:
        return None, error
    if "moveTo" in payload:
        params["moveTo"] = payload["moveTo"]
    if "junk" in payload:
        params["junk"] = payload["junk"]
    return params, ""


# ---------------------------------------------------------------------------
# Body policy for folder create/rename
# ---------------------------------------------------------------------------


def _json_object(body: bytes, allowed: frozenset[str]) -> tuple[dict[str, Any] | None, str]:
    """Parse a JSON object body and reject unknown keys."""
    try:
        payload = json.loads(body)
    except ValueError:
        return None, "body must be valid JSON"
    if not isinstance(payload, dict):
        return None, "body must be a JSON object"
    unknown = set(payload) - allowed
    if unknown:
        return None, f"unsupported field: {sorted(unknown)[0]} (allowed: {', '.join(sorted(allowed))})"
    return payload, ""


def _folder_name(payload: dict[str, Any]) -> tuple[str, str]:
    name = payload.get("name")
    if not isinstance(name, str) or not name.strip():
        return "", "name is required and must be a non-empty string"
    if "/" in name:
        return "", "name must not contain '/'"
    return name, ""


def validate_folder_create_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse a folders.create POST body: a name plus a parent locator.

    The parent is a raw ``parentFolderId``, or an ``account`` + ``folder``
    (name or path) pair resolved by the add-on — the same locators
    /mail/list accepts.
    """
    payload, error = _json_object(body, frozenset({"name", "parentFolderId", "account", "folder"}))
    if payload is None:
        return None, error
    name, error = _folder_name(payload)
    if error:
        return None, error
    for key in ("parentFolderId", "account", "folder"):
        if key in payload and (not isinstance(payload[key], str) or not payload[key].strip()):
            return None, f"{key} must be a non-empty string"
    if "parentFolderId" in payload and ("account" in payload or "folder" in payload):
        return None, "specify one parent locator: parentFolderId or account + folder, not both"
    params: dict[str, Any] = {"name": name}
    if isinstance(payload.get("parentFolderId"), str):
        params["folderId"] = payload["parentFolderId"]
    for key in ("account", "folder"):
        if isinstance(payload.get(key), str):
            params[key] = payload[key]
    if "folderId" not in params and not ("account" in params and "folder" in params):
        return None, "parentFolderId (or account + folder) is required"
    return params, ""


def validate_folder_update_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse a folders.update PATCH body: {"name": "<new name>"}."""
    payload, error = _json_object(body, frozenset({"name"}))
    if payload is None:
        return None, error
    name, error = _folder_name(payload)
    if error:
        return None, error
    return {"name": name}, ""


MAX_MOVE_IDS = 500


def _message_ids(payload: dict[str, Any]) -> tuple[list[str] | None, str]:
    """Validate the shared batch 'ids' field: strings or numbers, 1..cap.

    The listing hands ids out as numbers, agents copy them either way; the
    add-on converts them with Number(). Only Thunderbird's native batch
    APIs (messages.move, messages.delete) back the batch endpoints — a
    batched flags update would just hide N sequential IMAP commands behind
    one request and hit the same server-side rate limits.
    """
    ids = payload.get("ids")
    if (
        not isinstance(ids, list)
        or not ids
        or not all(isinstance(i, (str, int)) and not isinstance(i, bool) and str(i).strip() for i in ids)
    ):
        return None, "ids must be a non-empty array of message ids"
    if len(ids) > MAX_MOVE_IDS:
        return None, f"ids must contain at most {MAX_MOVE_IDS} message ids"
    return [str(i) for i in ids], ""


def _flag_params(payload: dict[str, Any]) -> tuple[dict[str, Any] | None, str]:
    """Extract read/starred/tags from a body, translating starred→flagged."""
    if "read" in payload and not isinstance(payload["read"], bool):
        return None, "read must be a boolean"
    if "starred" in payload and not isinstance(payload["starred"], bool):
        return None, "starred must be a boolean"
    if "tags" in payload:
        # An empty array is valid — it clears the messages' tags.
        error = _recipient_list(payload["tags"], "tags", "tag names", allow_empty=True)
        if error:
            return None, error
    params: dict[str, Any] = {k: v for k, v in payload.items() if k in ("read", "starred", "tags")}
    if "starred" in params:
        params["flagged"] = params.pop("starred")
    return params, ""


def validate_move_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse a messages.move POST body: {"ids": [...], "to": "<folderId>"}."""
    try:
        payload = json.loads(body)
    except ValueError:
        return None, "body must be valid JSON"
    if not isinstance(payload, dict):
        return None, "body must be a JSON object"
    unknown = set(payload) - {"ids", "to"}
    if unknown:
        return None, "unsupported field: " + sorted(unknown)[0]
    ids, error = _message_ids(payload)
    if ids is None:
        return None, error
    to = payload.get("to")
    if not isinstance(to, str) or not to.strip():
        return None, "to must be a folder id string"
    return {"ids": ids, "to": to}, ""


def validate_trash_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse a messages.trash POST body: {"ids": [...]} — nothing else."""
    payload, error = _json_object(body, frozenset({"ids"}))
    if payload is None:
        return None, error
    ids, error = _message_ids(payload)
    if ids is None:
        return None, error
    return {"ids": ids}, ""


def _folder_locator(payload: dict[str, Any]) -> tuple[dict[str, Any] | None, str]:
    """Validate a folder locator: a raw folderId, or an account + folder
    (name or path) pair resolved by the add-on. Mutually exclusive."""
    for key in ("folderId", "account", "folder"):
        if key in payload and (not isinstance(payload[key], str) or not payload[key].strip()):
            return None, f"{key} must be a non-empty string"
    if "folderId" in payload and ("account" in payload or "folder" in payload):
        return None, "specify one locator: folderId or account + folder, not both"
    if "folderId" not in payload and not ("account" in payload and "folder" in payload):
        return None, "folderId (or account + folder) is required"
    return {k: v for k, v in payload.items() if k in ("folderId", "account", "folder")}, ""


def validate_folder_read_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse a folders.markRead POST body: a folder locator."""
    payload, error = _json_object(body, frozenset({"folderId", "account", "folder"}))
    if payload is None:
        return None, error
    return _folder_locator(payload)


def validate_mark_body(body: bytes) -> tuple[dict[str, Any] | None, str]:
    """Parse a messages.mark POST body: ids and at least one of read/starred.

    No folder is needed — the experiment API resolves the session message ids
    through the extension's own message manager (the same lookup as a single
    update), which knows each message's folder. Tags are not part of this
    endpoint (no native bulk path — use PATCH /mail/{id}).
    """
    payload, error = _json_object(body, frozenset({"ids", "read", "starred"}))
    if payload is None:
        return None, error
    ids, error = _message_ids(payload)
    if ids is None:
        return None, error
    if "read" not in payload and "starred" not in payload:
        return None, "at least one of read, starred is required"
    params, error = _flag_params(payload)
    if params is None:
        return None, error
    return {"ids": ids, **params}, ""


def extract_recipients(params: dict[str, Any]) -> list[str]:
    """All recipient addresses of a send/draft command, lowercased."""
    recipients: list[str] = []
    for key in ("to", "cc", "bcc"):
        value = params.get(key)
        if isinstance(value, list):
            recipients.extend(str(v).strip().lower() for v in value)
    return recipients
