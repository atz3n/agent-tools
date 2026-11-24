#!/usr/bin/env python3
"""Configuration and logging for the LLM inference proxy."""

from __future__ import annotations

import logging
import os
import sys
import time

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("PROXY_PORT") or "8089")
# Inside Docker the image must bind all interfaces; compose's 127.0.0.1 port
# mapping provides the localhost-only publish. Set BIND_HOST=127.0.0.1 when
# running the server directly on a host.
BIND_HOST = os.environ.get("BIND_HOST", "0.0.0.0")

# Credentials. The OpenRouter route is disabled when the key is absent;
# the mlx-serve route needs no credentials.
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "").strip()

# Optional client gate. When set, every request must present
# 'Authorization: Bearer <LLM_PROXY_TOKEN>'. Empty = open (localhost only).
LLM_PROXY_TOKEN = os.environ.get("LLM_PROXY_TOKEN", "").strip()

# Upstream targets. The mlx-serve target is a plain-HTTP OpenAI-compatible
# server; from inside Docker it is normally reached via the host gateway.
MLX_SERVE_URL = (os.environ.get("MLX_SERVE_URL") or "http://host.docker.internal:11234").rstrip("/")

# Read timeout for upstream connections. Reasoning models can stay silent
# for minutes between tokens, so this is deliberately long.
UPSTREAM_TIMEOUT = int(os.environ.get("LLM_UPSTREAM_TIMEOUT") or "600")

# Model allowlist for completion request bodies — both the /chat/completions
# and the /messages dialects, on every route. Empty = any model. When
# non-empty the gate is strict: a body without a parsable "model" is 400.
ALLOWED_MODELS = frozenset(m.strip() for m in os.environ.get("ALLOWED_MODELS", "").split(",") if m.strip())


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("llm-proxy")
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
    """Warn about degraded configuration.

    A missing OpenRouter key disables only the /openrouter route (the proxy
    still serves credential-free routes such as mlx-serve), so this warns
    rather than exiting.
    """
    if not OPENROUTER_API_KEY:
        print(
            "WARNING: OPENROUTER_API_KEY is not set — the /openrouter route is disabled",
            file=sys.stderr,
        )
