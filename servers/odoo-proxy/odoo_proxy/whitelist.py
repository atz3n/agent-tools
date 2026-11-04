#!/usr/bin/env python3
"""Endpoint whitelist for the Odoo proxy."""

import re

PathPattern = re.Pattern[str]

ALLOWED_PATHS: list[PathPattern] = [
    re.compile(p)
    for p in [
        r"^/task/data$",
        r"^/task/messages$",
        r"^/task/message$",
    ]
]


def is_allowed_endpoint(path: str) -> bool:
    """Check if path matches an allowed endpoint."""
    clean_path = path.split("?")[0]
    return any(p.match(clean_path) for p in ALLOWED_PATHS)
