#!/usr/bin/env python3
"""Endpoint whitelist for the tasks server."""

from __future__ import annotations

import re

PathPattern = re.Pattern[str]

ALLOWED_PATHS: list[PathPattern] = [
    re.compile(p)
    for p in [
        r"^/tasks$",
        r"^/tasks/\d+$",
        r"^/projects$",
        r"^/ui$",
        r"^/css/.*$",
        r"^/js/.*$",
    ]
]


def is_allowed_endpoint(path: str) -> bool:
    """Check if path matches an allowed endpoint."""
    clean_path = path.split("?")[0]
    return any(p.match(clean_path) for p in ALLOWED_PATHS)
