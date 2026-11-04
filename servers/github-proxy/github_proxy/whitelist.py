#!/usr/bin/env python3
"""Endpoint whitelist for the GitHub proxy (PR + issue endpoints)."""

from __future__ import annotations

import re

# ---------------------------------------------------------------------------
# PR endpoint whitelist (compiled regex patterns)
# ---------------------------------------------------------------------------

_PR_PATHS: list[str] = [
    # PR CRUD
    r"^/repos/[^/]+/[^/]+/pulls$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+$",
    # Review comments (repository-wide)
    r"^/repos/[^/]+/[^/]+/pulls/comments$",
    # Review comments (PR-specific)
    r"^/repos/[^/]+/[^/]+/pulls/\d+/comments$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/comments/\d+$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/comments/\d+/replies$",
    # Review comment reactions
    r"^/repos/[^/]+/[^/]+/pulls/comments/\d+/reactions$",
    r"^/repos/[^/]+/[^/]+/pulls/comments/\d+/reactions/\d+$",
    # Reviews
    r"^/repos/[^/]+/[^/]+/pulls/\d+/reviews$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/reviews/\d+$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/reviews/\d+/comments$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/reviews/\d+/dismissals$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/reviews/\d+/events$",
    # PR metadata
    r"^/repos/[^/]+/[^/]+/pulls/\d+/commits$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/files$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/merge$",
    r"^/repos/[^/]+/[^/]+/pulls/\d+/update-branch$",
    # Cross-ref: commits that return PRs
    r"^/repos/[^/]+/[^/]+/commits/[^/]+/pulls$",
    # Authenticated user (required to determine owner for PR endpoints)
    r"^/user$",
]

# ---------------------------------------------------------------------------
# Issue endpoint whitelist
# ---------------------------------------------------------------------------

_ISSUE_PATHS: list[str] = [
    # Issue CRUD (GitHub has no DELETE for issues — close via PATCH state=closed)
    r"^/repos/[^/]+/[^/]+/issues$",
    r"^/repos/[^/]+/[^/]+/issues/\d+$",
    # Issue / PR discussion comments
    r"^/repos/[^/]+/[^/]+/issues/\d+/comments$",
    r"^/repos/[^/]+/[^/]+/issues/\d+/comments/\d+$",
    # Issue labels
    r"^/repos/[^/]+/[^/]+/issues/\d+/labels$",
    r"^/repos/[^/]+/[^/]+/issues/\d+/labels/[^/]+$",
    # Issue assignees
    r"^/repos/[^/]+/[^/]+/issues/\d+/assignees$",
    # Repository labels (needed to pick valid labels when creating/updating issues)
    r"^/repos/[^/]+/[^/]+/labels$",
]

_ALLOWED_PATHS: list[str] = _PR_PATHS + _ISSUE_PATHS

_ALLOWED_PATTERNS: list[re.Pattern[str]] = [re.compile(p) for p in _ALLOWED_PATHS]


def is_allowed_endpoint(path: str) -> bool:
    """Check if path matches any allowed (PR or issue) endpoint pattern.

    Strips query parameters before matching.
    """
    clean_path = path.split("?")[0]
    return any(p.match(clean_path) for p in _ALLOWED_PATTERNS)
