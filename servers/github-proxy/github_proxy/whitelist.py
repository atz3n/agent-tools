#!/usr/bin/env python3
"""PR endpoint whitelist for the GitHub proxy."""

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
    # PR discussion comments (GitHub stores PR comments under the issues API)
    r"^/repos/[^/]+/[^/]+/issues/\d+/comments$",
    # Cross-ref: commits that return PRs
    r"^/repos/[^/]+/[^/]+/commits/[^/]+/pulls$",
    # Authenticated user (required to determine owner for PR endpoints)
    r"^/user$",
]

_PR_PATTERNS: list[re.Pattern[str]] = [re.compile(p) for p in _PR_PATHS]


def is_pr_endpoint(path: str) -> bool:
    """Check if path matches any PR endpoint pattern.

    Strips query parameters before matching.
    """
    clean_path = path.split("?")[0]
    return any(p.match(clean_path) for p in _PR_PATTERNS)
