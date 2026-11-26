#!/usr/bin/env python3
"""Configuration and logging for the Thunderbird proxy."""

from __future__ import annotations

import logging
import os
import sys
import time

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("PROXY_PORT") or "8090")
# Inside Docker the image must bind all interfaces; compose's 127.0.0.1 port
# mapping provides the localhost-only publish. Set BIND_HOST=127.0.0.1 when
# running the server directly on a host.
BIND_HOST = os.environ.get("BIND_HOST", "0.0.0.0")

# Shared secret between the proxy, the agent callers, and the Thunderbird
# add-on. Mandatory: this proxy can read and send mail, so unlike the
# llm-proxy gate there is no open default.
THUNDERBIRD_PROXY_TOKEN = os.environ.get("THUNDERBIRD_PROXY_TOKEN", "").strip()

# How long an agent request waits for the add-on to execute its command.
COMMAND_TIMEOUT = int(os.environ.get("COMMAND_TIMEOUT") or "30")

# Long-poll window the add-on's GET /addon/poll is held open for.
ADDON_POLL_WAIT = 30

# No poll/hello from the add-on for this long -> considered disconnected.
ADDON_STALE_AFTER = 90

# Optional recipient allowlist for message.send / message.draft.
# Empty = any recipient. Entries are compared lowercased.
ALLOWED_SENDERS = frozenset(
    s.strip().lower() for s in os.environ.get("ALLOWED_SENDERS", "").split(",") if s.strip()
)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("thunderbird-proxy")
logger.setLevel(logging.INFO)
logger.handlers.clear()  # keep module reloads idempotent
_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(logging.Formatter("[proxy] %(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%SZ"))
_handler.converter = time.gmtime  # type: ignore[reportAttributeAccessIssue]  # UTC timestamps
logger.addHandler(_handler)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def validate_config() -> None:
    """Exit unless the mandatory shared token is configured."""
    if not THUNDERBIRD_PROXY_TOKEN:
        print(
            "ERROR: THUNDERBIRD_PROXY_TOKEN is not set — it is mandatory "
            "(both the agent face and the add-on face are gated by it)",
            file=sys.stderr,
        )
        sys.exit(1)
