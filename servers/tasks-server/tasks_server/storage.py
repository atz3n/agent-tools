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
from datetime import datetime, timezone

from . import config

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
        inner = raw[1:-1].strip()
        if not inner:
            return []
        items = []
        for item in _split_csv(inner):
            item = item.strip().strip('"').strip("'")
            items.append(item)
        return items
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
            items = ", ".join(f'"{v}"' for v in value)
            lines.append(f"{key}: [{items}]")
        elif isinstance(value, (int, float)):
            lines.append(f"{key}: {value}")
        else:
            lines.append(f'{key}: "{value}"')
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Filename helpers
# ---------------------------------------------------------------------------

# Matches files like 001_fix-login.md, 042_something.md
_TASK_FILE_RE = re.compile(r"^(\d{3})_(.+)\.md$")


def _filename_from_title(task_id: int, title: str) -> str:
    """Generate a filename from a task ID and title."""
    slug = title.lower().strip()
    # Replace spaces with hyphens
    slug = re.sub(r"\s+", "-", slug)
    # Keep alphanumeric, hyphens, underscores; strip everything else
    slug = re.sub(r"[^a-z0-9_-]", "", slug)
    slug = slug.strip("-_")
    if not slug:
        slug = "untitled"
    return f"{task_id:03d}_{slug}.md"


# ---------------------------------------------------------------------------
# Counter management
# ---------------------------------------------------------------------------


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


def _task_file_path(project: str, task_id: int, title: str = "") -> str:
    """Return the filesystem path for a task file."""
    project_dir = os.path.join(config.TASKS_DIR, project)
    if title:
        fname = _filename_from_title(task_id, title)
    else:
        fname = f"{task_id:03d}_{task_id}.md"
    return os.path.join(project_dir, fname)


def _ensure_project_dir(project: str) -> None:
    """Create the project directory if it doesn't exist."""
    os.makedirs(os.path.join(config.TASKS_DIR, project), exist_ok=True)


def _internal_keys() -> set[str]:
    """Keys that are internal to the storage layer and should not be persisted."""
    return {"filename", "project"}


def create_task(
    title: str,
    project: str = "default",
    status: str = "open",
    priority: str = "medium",
    due_date: str | None = None,
    tags: list[str] | None = None,
    description: str = "",
) -> dict:
    """Create a new task. Returns the task dict."""
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
    for entry in sorted(os.listdir(config.TASKS_DIR)):
        project_dir = os.path.join(config.TASKS_DIR, entry)
        if not os.path.isdir(project_dir):
            continue
        for fname in os.listdir(project_dir):
            if not pattern.match(fname):
                continue
            path = os.path.join(project_dir, fname)
            with open(path, "r") as f:
                content = f.read()
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
    """Update a task by ID. Returns the updated task or None."""
    task = get_task(task_id)
    if task is None:
        return None

    # Merge updates (only known fields)
    known_fields = {"title", "status", "priority", "due_date", "tags", "description"}
    for key, value in updates.items():
        if key in known_fields:
            task[key] = value

    task["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    project = task.get("project", "default")
    body = f"## Description\n\n{task.get('description', '')}\n" if task.get("description") else ""
    fm = {
        "id": task["id"],
        "title": task["title"],
        "status": task["status"],
        "priority": task["priority"],
        "due_date": task.get("due_date"),
        "tags": task.get("tags", []),
        "created_at": task["created_at"],
        "updated_at": task["updated_at"],
    }
    content = f"---\n{format_frontmatter(fm)}\n---\n\n{body}"

    # Rename file if title changed
    old_fname = task.get("filename", f"{task_id:03d}_{task_id}.md")
    new_fname = _filename_from_title(task_id, task["title"])
    old_path = os.path.join(config.TASKS_DIR, project, old_fname)
    new_path = os.path.join(config.TASKS_DIR, project, new_fname)
    if old_fname != new_fname and os.path.exists(old_path):
        os.rename(old_path, new_path)
    task["filename"] = new_fname

    with open(new_path, "w") as f:
        f.write(content)

    return dict(task)


def delete_task(task_id: int) -> bool:
    """Delete a task by ID. Returns True if deleted, False if not found."""
    pattern = re.compile(rf"^{task_id:03d}_.*\.md$")
    for entry in sorted(os.listdir(config.TASKS_DIR)):
        project_dir = os.path.join(config.TASKS_DIR, entry)
        if not os.path.isdir(project_dir):
            continue
        for fname in os.listdir(project_dir):
            if not pattern.match(fname):
                continue
            path = os.path.join(project_dir, fname)
            os.remove(path)
            # Clean up empty project dirs
            if not os.listdir(project_dir):
                os.rmdir(project_dir)
            return True
    return False


def list_tasks(project: str | None = None, status: str | None = None) -> list[dict]:
    """List all tasks, optionally filtered by project and/or status."""
    tasks: list[dict] = []
    scan_dirs: list[str] = []

    if project:
        scan_dirs = [project]
    else:
        for entry in sorted(os.listdir(config.TASKS_DIR)):
            project_dir = os.path.join(config.TASKS_DIR, entry)
            if os.path.isdir(project_dir):
                scan_dirs.append(entry)

    for proj in scan_dirs:
        project_dir = os.path.join(config.TASKS_DIR, proj)
        if not os.path.isdir(project_dir):
            continue
        for fname in sorted(os.listdir(project_dir)):
            m = _TASK_FILE_RE.match(fname)
            if not m:
                continue
            fpath = os.path.join(project_dir, fname)
            with open(fpath, "r") as f:
                content = f.read()
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
    for entry in sorted(os.listdir(config.TASKS_DIR)):
        project_dir = os.path.join(config.TASKS_DIR, entry)
        if os.path.isdir(project_dir) and not entry.startswith("."):
            projects.append(entry)
    return projects
