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
    # Requested reviewers (list / add / remove). GitHub's route uses an
    # underscore: /pulls/{n}/requested_reviewers
    r"^/repos/[^/]+/[^/]+/pulls/\d+/requested_reviewers$",
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
    # Single issue comment — GitHub's get/update/delete route is comment-scoped
    # (/issues/comments/{id}); there is no /issues/{n}/comments/{id} route.
    r"^/repos/[^/]+/[^/]+/issues/comments$",
    r"^/repos/[^/]+/[^/]+/issues/comments/\d+$",
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

# ---------------------------------------------------------------------------
# Path aliases
# ---------------------------------------------------------------------------

# Accepted alias paths rewritten to GitHub's canonical routes before the
# whitelist check and forwarding. GitHub's requested-reviewers route uses an
# underscore (/pulls/{n}/requested_reviewers); the hyphenated alias matches
# GitHub's operation-id style and is what agents tend to reach for.
_PATH_ALIASES: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"^(?P<prefix>/repos/[^/]+/[^/]+/pulls/\d+)/requested-reviewers$"),
        r"\g<prefix>/requested_reviewers",
    ),
]


def normalize_path(path: str) -> str:
    """Rewrite alias paths to their canonical GitHub route.

    Query parameters are preserved.
    """
    clean_path, sep, query = path.partition("?")
    for pattern, repl in _PATH_ALIASES:
        clean_path = pattern.sub(repl, clean_path)
    return clean_path + (sep + query if sep else "")


def is_allowed_endpoint(path: str) -> bool:
    """Check if path matches any allowed (PR or issue) endpoint pattern.

    Strips query parameters before matching.
    """
    clean_path = path.split("?")[0]
    return any(p.match(clean_path) for p in _ALLOWED_PATTERNS)
