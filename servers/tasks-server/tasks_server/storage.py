#!/usr/bin/env python3
"""Task storage backed by markdown files with YAML frontmatter.

Tasks are stored as .md files under project subdirectories inside TASKS_DIR.
File names follow the ``{id:03d}_{title}.md`` pattern (e.g. ``001_fix-login.md``)
for easy manual discovery.

An auto-incrementing ID is persisted in .counter.json.

No external dependencies — frontmatter is parsed manually.
"""

from __future__ import annotations

import json
import os
import re
import threading
from datetime import datetime, timezone

from . import config

# ---------------------------------------------------------------------------
# Status/priority vocabularies (single source of truth — kept in sync with
# README, spec/openapi.yml and the web UI). The HTTP layer rejects unknown
# values; reads stay lenient (hand-edited files fall back via update_task).
# ---------------------------------------------------------------------------

VALID_STATUSES: frozenset[str] = frozenset({"open", "in-progress", "on-hold", "done", "closed"})

VALID_PRIORITIES: frozenset[str] = frozenset({"low", "medium", "high"})

# ---------------------------------------------------------------------------
# Project-name safety
# ---------------------------------------------------------------------------

# A project name is a single path segment: no separators, no traversal,
# no leading dot (hidden files like .counter.json stay out of reach).
# Everything else — letters, digits, spaces, hyphens, underscores, dots —
# is fine, which covers every project dir created so far.
_PROJECT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ -]*\Z")


def valid_project_name(name: object) -> bool:
    """True when ``name`` is a safe single-segment project directory name."""
    return isinstance(name, str) and bool(_PROJECT_NAME_RE.match(name))


def _safe_scan_entry(entry: str) -> bool:
    """True when a directory entry found while scanning stays under TASKS_DIR.

    Guards reads against hand-planted symlink/dot segment directories that
    predate name validation; anything resolving outside TASKS_DIR is skipped.
    """
    if entry in (".", "..") or entry.startswith("."):
        return False
    root = os.path.realpath(config.TASKS_DIR)
    target = os.path.realpath(os.path.join(config.TASKS_DIR, entry))
    return target.startswith(root + os.sep)


def _list_dir(path: str) -> list[str]:
    """Sorted directory listing; an empty list when the dir vanished or is
    unreadable — one odd entry must never take down a whole listing."""
    try:
        return sorted(os.listdir(path))
    except OSError as exc:
        config.logger.warning("skipping unreadable directory %s (%s)", path, exc)
        return []


def _read_task_file(path: str) -> str | None:
    """Read a task file's text; None when it is unreadable.

    Hand-edited or concurrently removed files (non-UTF-8 bytes, a directory
    named ``NNN_x.md``, a dangling symlink, a task deleted between listing
    and read) are skipped with a warning instead of crashing the handler.
    """
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()
    except OSError as exc:
        config.logger.warning("skipping unreadable task file %s (%s)", path, exc)
        return None


# ---------------------------------------------------------------------------
# Frontmatter parsing (no PyYAML)
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n?(.*)", re.DOTALL)

# Patterns recognized inside frontmatter blocks
_SCALAR_RE = re.compile(r'^(\w+):\s*(.+)$')
_NULL_RE = re.compile(r'^(\w+):\s*$')
_NULL_RE2 = re.compile(r'^(\w+):\s+None\s*$')


def _parse_value(raw: str) -> str | int | float | bool | list[str] | None:
    """Parse a single frontmatter value string into a Python type."""
    raw = raw.strip()
    if not raw or raw.lower() == "null":
        return None
    if raw.lower() == "true":
        return True
    if raw.lower() == "false":
        return False
    # Try integer
    try:
        return int(raw)
    except ValueError:
        pass
    # Try float
    try:
        return float(raw)
    except ValueError:
        pass
    # Inline list ["tag1", "tag2"] — check BEFORE quotes
    if raw.startswith("[") and raw.endswith("]"):
        # Writer-produced lists are JSON — parse them exactly, escaping and all.
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
        if isinstance(parsed, list):
            return [x if isinstance(x, str) else str(x) for x in parsed]
        inner = raw[1:-1].strip()
        if not inner:
            return []
        items = []
        for item in _split_csv(inner):
            item = item.strip().strip('"').strip("'")
            items.append(item)
        return items
    # Double-quoted strings — writer output is JSON-escaped, so decode with
    # json first (round-trips \n, \" …); fall back to plain quote-stripping
    # for hand-written files (e.g. "a"b" which is not valid JSON).
    if raw.startswith('"') and raw.endswith('"'):
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
        if isinstance(parsed, str):
            return parsed
    # Strip surrounding quotes (must come before comma check)
    if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")):
        return raw[1:-1]
    # Comma-separated quoted strings (array content from frontmatter regex)
    if ',' in raw:
        items = []
        for item in _split_csv(raw):
            item = item.strip().strip('"').strip("'")
            if item:
                items.append(item)
        if items:
            return items
    return raw


def _split_csv(s: str) -> list[str]:
    """Split a CSV string respecting quotes."""
    items: list[str] = []
    current: list[str] = []
    in_quotes = False
    quote_char: str = ""
    for ch in s:
        if in_quotes:
            if ch == quote_char:
                in_quotes = False
            else:
                current.append(ch)
        elif ch in ('"', "'"):
            in_quotes = True
            quote_char = ch
        elif ch == ",":
            items.append("".join(current))
            current = []
        else:
            current.append(ch)
    if current:
        items.append("".join(current))
    return items


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Parse markdown text with YAML-like frontmatter.

    Returns (frontmatter_dict, body_string).
    """
    m = _FRONTMATTER_RE.match(text)
    if not m:
        return {}, text

    fm_raw = m.group(1)
    body = m.group(2)
    fm: dict = {}

    for line in fm_raw.splitlines():
        line = line.strip()
        if not line:
            continue
        # Null: due_date:
        nm = _NULL_RE.match(line)
        if nm:
            fm[nm.group(1)] = None
            continue
        # Null explicit: due_date: None
        nm2 = _NULL_RE2.match(line)
        if nm2:
            fm[nm2.group(1)] = None
            continue
        # Scalar (covers arrays like tags: ["bug", "auth"] too — _parse_value handles it)
        sm = _SCALAR_RE.match(line)
        if sm:
            key, val = sm.group(1), sm.group(2)
            fm[key] = _parse_value(val)

    return fm, body


def format_frontmatter(fm: dict) -> str:
    """Serialize a frontmatter dict to YAML-like text (no PyYAML)."""
    lines: list[str] = []
    for key, value in fm.items():
        if value is None:
            lines.append(f"{key}:")
        elif isinstance(value, bool):
            lines.append(f"{key}: {'true' if value else 'false'}")
        elif isinstance(value, list):
            items = ", ".join(json.dumps(v, ensure_ascii=False) for v in value)
            lines.append(f"{key}: [{items}]")
        elif isinstance(value, (int, float)):
            lines.append(f"{key}: {value}")
        else:
            lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Filename helpers
# ---------------------------------------------------------------------------

# Matches files like 001_fix-login.md, 042_something.md, 1000_rolled-over.md
_TASK_FILE_RE = re.compile(r"^(\d{3,})_(.+)\.md$")


def _filename_from_title(task_id: int, title: str) -> str:
    """Generate a filename from a task ID and title (slug clamped to 80 chars)."""
    slug = title.lower().strip()
    # Replace spaces with hyphens
    slug = re.sub(r"\s+", "-", slug)
    # Keep alphanumeric, hyphens, underscores; strip everything else
    slug = re.sub(r"[^a-z0-9_-]", "", slug)
    # Clamp: a filesystem path segment caps at 255 bytes — an unclamped
    # long title would crash the write with ENAMETOOLONG.
    slug = slug[:80].strip("-_")
    if not slug:
        slug = "untitled"
    return f"{task_id:03d}_{slug}.md"


# ---------------------------------------------------------------------------
# Counter management
# ---------------------------------------------------------------------------


_counter_lock = threading.Lock()  # read-modify-write must be atomic under ThreadingHTTPServer


def _read_counter() -> int:
    """Read the next ID counter from .counter.json."""
    path = os.path.join(config.TASKS_DIR, ".counter.json")
    with open(path, "r") as f:
        data = json.load(f)
    return int(data.get("next_id", 1))


def _write_counter(next_id: int) -> None:
    """Write the next ID counter to .counter.json."""
    path = os.path.join(config.TASKS_DIR, ".counter.json")
    with open(path, "w") as f:
        json.dump({"next_id": next_id}, f)


# ---------------------------------------------------------------------------
# Task CRUD
# ---------------------------------------------------------------------------


def _ensure_project_dir(project: str) -> None:
    """Create the project directory if it doesn't exist.

    Raises ValueError for names that could escape TASKS_DIR (separators,
    ``..``, leading dots) and for names that a hand-managed volume already
    occupies with a non-directory entry — the single choke point every
    write path goes through, so it must never let an OSError escape.
    """
    if not valid_project_name(project):
        raise ValueError(f"invalid project name: {project!r}")
    try:
        os.makedirs(os.path.join(config.TASKS_DIR, project), exist_ok=True)
    except FileExistsError as exc:
        # ``exist_ok`` only covers the directory-already-exists case; a plain
        # file with the project's name would drop the connection unlogged.
        raise ValueError(
            f"project name exists as a non-directory: {project!r}"
        ) from exc
    except OSError as exc:
        raise ValueError(f"cannot create project directory: {project!r} ({exc})") from exc


def create_task(
    title: str,
    project: str = "default",
    status: str = "open",
    priority: str = "medium",
    due_date: str | None = None,
    tags: list[str] | None = None,
    description: str = "",
) -> dict:
    """Create a new task. Returns the task dict.

    The counter read and increment bracket the file write under
    ``_counter_lock`` so concurrent creates (ThreadingHTTPServer) can never
    hand out the same id twice.
    """
    with _counter_lock:
        task_id = _read_counter()
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        fm = {
            "id": task_id,
            "title": title,
            "status": status,
            "priority": priority,
            "due_date": due_date,
            "tags": tags or [],
            "created_at": now,
            "updated_at": now,
        }

        _ensure_project_dir(project)
        body = f"## Description\n\n{description}\n" if description else ""
        content = f"---\n{format_frontmatter(fm)}\n---\n\n{body}"

        fname = _filename_from_title(task_id, title)
        path = os.path.join(config.TASKS_DIR, project, fname)
        with open(path, "w") as f:
            f.write(content)

        _write_counter(task_id + 1)

    result = dict(fm)
    result["description"] = description
    result["project"] = project
    result["filename"] = fname
    return result


def get_task(task_id: int) -> dict | None:
    """Get a task by ID. Returns None if not found."""
    pattern = re.compile(rf"^{task_id:03d}_.*\.md$")
    for entry in _list_dir(config.TASKS_DIR):
        project_dir = os.path.join(config.TASKS_DIR, entry)
        if not os.path.isdir(project_dir) or not _safe_scan_entry(entry):
            continue
        for fname in _list_dir(project_dir):
            if not pattern.match(fname):
                continue
            path = os.path.join(project_dir, fname)
            content = _read_task_file(path)
            if content is None:
                continue
            fm, body = parse_frontmatter(content)
            result = dict(fm)
            # Clean body for description
            desc_match = re.search(r"## Description\s*\n(.*)", body, re.DOTALL)
            result["description"] = desc_match.group(1).strip() if desc_match else ""
            # Derive project and filename from path
            result["project"] = entry
            result["filename"] = fname
            return result
    return None


def update_task(task_id: int, updates: dict) -> dict | None:
    """Update a task by ID. Returns the updated task or None.

    A ``project`` update moves the task file into the new project folder.
    """
    task = get_task(task_id)
    if task is None:
        return None

    old_project = task.get("project", "default")
    old_fname = task.get("filename", f"{task_id:03d}_{task_id}.md")

    # Merge updates (only known fields)
    known_fields = {"title", "status", "priority", "due_date", "tags", "description", "project"}
    for key, value in updates.items():
        if key == "project":
            # Partial-update semantics: ignore absent/empty/non-string values;
            # syntactically invalid names are rejected by _ensure_project_dir
            # (ValueError → 400 at the HTTP layer).
            if isinstance(value, str) and value.strip():
                task["project"] = value.strip()
            continue
        if key in known_fields:
            task[key] = value

    task["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # A hand-edited file may be missing frontmatter keys — backfill instead
    # of crashing the handler with a KeyError (nothing here is guaranteed
    # beyond what parse_frontmatter found).
    if not isinstance(task.get("id"), int):
        task["id"] = task_id
    if not isinstance(task.get("title"), str) or not task["title"].strip():
        slug = old_fname.split("_", 1)[-1].removesuffix(".md").replace("-", " ").strip()
        task["title"] = slug or f"task {task_id}"
    if not isinstance(task.get("status"), str) or not task["status"]:
        task["status"] = "open"
    if not isinstance(task.get("priority"), str) or not task["priority"]:
        task["priority"] = "medium"
    if not isinstance(task.get("created_at"), str) or not task["created_at"]:
        task["created_at"] = task["updated_at"]

    project = task.get("project", "default")
    task["project"] = project
    body = f"## Description\n\n{task.get('description', '')}\n" if task.get("description") else ""
    fm = {
        "id": task["id"],
        "title": task["title"],
        "status": task["status"],
        "priority": task["priority"],
        "due_date": task.get("due_date"),
        "tags": task.get("tags") if isinstance(task.get("tags"), list) else [],
        "created_at": task["created_at"],
        "updated_at": task["updated_at"],
    }
    content = f"---\n{format_frontmatter(fm)}\n---\n\n{body}"

    # Write under the (possibly new) project and title, then remove the old
    # file if the task moved or was renamed.
    new_fname = _filename_from_title(task_id, task["title"])
    _ensure_project_dir(project)
    new_path = os.path.join(config.TASKS_DIR, project, new_fname)
    with open(new_path, "w") as f:
        f.write(content)

    old_path = os.path.join(config.TASKS_DIR, old_project, old_fname)
    if old_path != new_path and os.path.exists(old_path):
        try:
            os.remove(old_path)
        except OSError as exc:
            # Rename already succeeded; a vanished old file (concurrent
            # delete) must not fail the update.
            config.logger.warning("could not remove stale task file %s (%s)", old_path, exc)
    task["filename"] = new_fname

    return dict(task)


def delete_task(task_id: int) -> bool:
    """Delete a task by ID. Returns True if deleted, False if not found."""
    pattern = re.compile(rf"^{task_id:03d}_.*\.md$")
    for entry in _list_dir(config.TASKS_DIR):
        project_dir = os.path.join(config.TASKS_DIR, entry)
        if not os.path.isdir(project_dir) or not _safe_scan_entry(entry):
            continue
        for fname in _list_dir(project_dir):
            if not pattern.match(fname):
                continue
            path = os.path.join(project_dir, fname)
            try:
                os.remove(path)
            except OSError as exc:
                # Vanished or unremovable (concurrent delete) — keep scanning.
                config.logger.warning("could not remove task file %s (%s)", path, exc)
                continue
            return True
    return False


def list_tasks(project: str | None = None, status: str | None = None) -> list[dict]:
    """List all tasks, optionally filtered by project and/or status."""
    tasks: list[dict] = []
    scan_dirs: list[str] = []

    if project:
        if not valid_project_name(project):
            return []
        scan_dirs = [project]
    else:
        for entry in _list_dir(config.TASKS_DIR):
            project_dir = os.path.join(config.TASKS_DIR, entry)
            if os.path.isdir(project_dir) and _safe_scan_entry(entry):
                scan_dirs.append(entry)

    for proj in scan_dirs:
        project_dir = os.path.join(config.TASKS_DIR, proj)
        if not os.path.isdir(project_dir):
            continue
        for fname in _list_dir(project_dir):
            m = _TASK_FILE_RE.match(fname)
            if not m:
                continue
            fpath = os.path.join(project_dir, fname)
            content = _read_task_file(fpath)
            if content is None:
                continue
            fm, body = parse_frontmatter(content)
            task = dict(fm)
            desc_match = re.search(r"## Description\s*\n(.*)", body, re.DOTALL)
            task["description"] = desc_match.group(1).strip() if desc_match else ""
            task["project"] = proj
            task["filename"] = fname

            # Apply filters
            if status and task.get("status") != status:
                continue
            tasks.append(task)

    return tasks


def create_project(name: str) -> str:
    """Create a new project directory. Returns the project name."""
    _ensure_project_dir(name)
    return name


def list_projects() -> list[str]:
    """List all project directories (excluding hidden files like .counter.json)."""
    projects: list[str] = []
    for entry in _list_dir(config.TASKS_DIR):
        project_dir = os.path.join(config.TASKS_DIR, entry)
        if os.path.isdir(project_dir) and _safe_scan_entry(entry):
            projects.append(entry)
    return projects
