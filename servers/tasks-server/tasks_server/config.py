#!/usr/bin/env python3
"""Configuration, logging, and initialization for the tasks server."""

from __future__ import annotations

import logging
import os
import sys
import time

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("PROXY_PORT", "8088"))
TASKS_DIR = os.environ.get("TASKS_DIR", "/data/tasks/")

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("tasks-proxy")
logger.setLevel(logging.INFO)
_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(logging.Formatter("[proxy] %(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%SZ"))
_handler.converter = time.gmtime  # type: ignore[reportAttributeAccessIssue]  # UTC timestamps
logger.addHandler(_handler)


# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------


def init_tasks_dir(tasks_dir: str | None = None) -> None:
    """Create TASKS_DIR and .counter.json if they don't exist."""
    import json

    target = tasks_dir or TASKS_DIR
    os.makedirs(target, exist_ok=True)

    counter_path = os.path.join(target, ".counter.json")
    if not os.path.exists(counter_path):
        with open(counter_path, "w") as f:
            json.dump({"next_id": 1}, f)
