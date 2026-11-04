#!/usr/bin/env python3
"""Configuration and logging for the GitHub PR-only proxy."""

from __future__ import annotations

import logging
import os
import sys
import time

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TARGET = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN", "")
PORT = int(os.environ.get("PROXY_PORT", "8086"))


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("github-proxy")
logger.setLevel(logging.INFO)
_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(logging.Formatter("[proxy] %(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%SZ"))
_handler.converter = time.gmtime  # type: ignore[reportAttributeAccessIssue]  # UTC timestamps
logger.addHandler(_handler)


# ---------------------------------------------------------------------------
# Token validation
# ---------------------------------------------------------------------------


def validate_token() -> None:
    """Exit with error if the GitHub token is not set."""
    if not TOKEN:
        print("ERROR: GITHUB_PERSONAL_ACCESS_TOKEN is not set", file=sys.stderr)
        sys.exit(1)
