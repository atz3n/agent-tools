#!/usr/bin/env python3
"""Configuration, logging, and credential loading for the Odoo proxy."""

import logging
import os
import sys
import time

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("PROXY_PORT", "8087"))

# Session timeout in seconds (default 45 min). Refreshed on 403/redirect.
SESSION_TIMEOUT = int(os.environ.get("ODOO_SESSION_TIMEOUT", "2700"))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("odoo-proxy")
logger.setLevel(logging.INFO)
_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(logging.Formatter("[proxy] %(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%SZ"))
_handler.converter = time.gmtime  # type: ignore[reportAttributeAccessIssue]  # UTC timestamps
logger.addHandler(_handler)

# ---------------------------------------------------------------------------
# Type aliases
# ---------------------------------------------------------------------------

Config = dict  # {"db": str, "url": str, "user": str, "password": str}


# ---------------------------------------------------------------------------
# Credential loading
# ---------------------------------------------------------------------------


def load_config() -> Config:
    """Load Odoo configuration from environment variables.

    Required env vars:
      ODOO_DB, ODOO_URL, ODOO_USER, ODOO_PASSWORD

    Exits with error if any required variable is missing.
    """
    db = os.environ.get("ODOO_DB", "")
    url = os.environ.get("ODOO_URL", "")
    user = os.environ.get("ODOO_USER", "")
    password = os.environ.get("ODOO_PASSWORD", "")

    missing = [k for k, v in [("db", db), ("url", url), ("user", user), ("password", password)] if not v]
    if missing:
        print(f"ERROR: missing environment variable ODOO_{missing[0].upper()}", file=sys.stderr)
        sys.exit(1)

    return {"db": db, "url": url, "user": user, "password": password}
