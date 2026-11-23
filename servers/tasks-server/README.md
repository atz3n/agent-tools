# Tasks Server

A lightweight REST API server for managing tasks stored as markdown files with YAML frontmatter. Tasks are organized in project folders with auto-incrementing IDs.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/tasks` | List all tasks (optional `?project=`, `?status=` filters) |
| GET | `/tasks/{id}` | Get a single task by ID |
| POST | `/tasks` | Create a new task |
| PATCH | `/tasks/{id}` | Update a task (partial update; a `project` change moves the task file, the source project directory stays) |
| DELETE | `/tasks/{id}` | Delete a task (the project directory is never removed — an emptied project stays listed) |
| GET | `/projects` | List all projects |
| POST | `/projects` | Create a new project |
| GET | `/ui` | Serve the web UI |

All other endpoints return **404 Not Found**. (The UI's assets are served from `/css/` and `/js/`.)

> **Note:** Only the HTTP methods listed in the table above are supported; other methods return 405 Method Not Allowed. **HEAD** is additionally supported on every GET path (`/tasks`, `/tasks/{id}`, `/projects`, `/ui`, `/css/*`, `/js/*`) and mirrors the status GET would return, without a body. OPTIONS and TRACE are not implemented — they return 501 from the HTTP layer itself (no `[proxy]` log line).

> **Project names** must be a single safe path segment — starting with a letter or digit, then letters, digits, spaces, `-`, `_`, `.`. Values containing `/`, `..`, or a leading dot are rejected with **400** everywhere they appear (`POST /projects`, `POST /tasks`, `PATCH /tasks/{id}`, and the `?project=` filter).

> **Field types** are validated on `POST /tasks` and `PATCH /tasks/{id}`: the body must be a JSON **object** (a non-object body or a malformed `Content-Length` returns **400**), `title` must be a non-empty string, `priority` one of `low`/`medium`/`high` (400 otherwise), `description` a string, `due_date` a `YYYY-MM-DD` string or null, `tags` a list of strings — anything else returns **400**.

## Web UI

A single-file, zero-dependency frontend is included at `ui/index.html`. It provides a clean, responsive interface for managing tasks:

- **Task list** with search, project, and status filters
- **Sidebar** with view filters (All, Open, In Progress, Done, Closed) and project list
- **Task detail panel** for editing title, status, priority, project, due date, tags, and description
- **Create task modal** with a full form
- **Delete confirmation** dialog
- **Keyboard shortcuts**: `Ctrl+K` to focus search, `Ctrl+N` for new task, `Esc` to close panels
- **Toast notifications** for success/error feedback

Access it at `http://localhost:8088/ui` after starting the server.

## Architecture

```
Client → :8088 (tasks-server) → /data/tasks/ (markdown files)
                              ↑ auto-incrementing IDs via .counter.json
                              ↑ project folders for organization
```

## Status

Tasks have five status values with this lifecycle:

```
open → in-progress → done | closed
  ↖      ↕
   on-hold
```

| Status | Description |
|--------|-------------|
| `open` | Task is ready to be worked on. |
| `in-progress` | Work has started on the task. |
| `on-hold` | Work is paused (blocked, waiting on someone); return it to `in-progress` to continue. |
| `done` | Work is complete. |
| `closed` | Task is closed (e.g. rejected, no longer needed). |

`done` and `closed` are sibling terminal states — both are reached from `in-progress`. The server validates `status` on create and update and rejects unknown values with **400**. This vocabulary is the single source of truth shared by `storage.VALID_STATUSES`, `spec/openapi.yml`, and the web UI. The same write-time gate polices `priority` against `storage.VALID_PRIORITIES` (`low`, `medium`, `high`).

## Task File Format

Tasks are stored as `.md` files with YAML-like frontmatter:

```markdown
---
id: 1
title: "Fix login bug"
status: open
priority: high
due_date: "2026-08-15"
tags: ["bug", "auth"]
created_at: "2026-07-27T10:00:00Z"
updated_at: "2026-07-27T10:00:00Z"
---

## Description

The login form does not submit when the password field is empty.
```

## Getting started

1. Build the server image: `./scripts/build-docker.sh`

2. Run the server: `./scripts/run-docker.sh`

The server is reachable at `http://localhost:8088`.

The web UI is available at `http://localhost:8088/ui`.

## Docker scripts

| Script | Description |
|--------|-------------|
| `./scripts/build-docker.sh` | Build the server image |
| `./scripts/run-docker.sh` | Start the server |
| `./scripts/pause-docker.sh` | Pause without removing containers |
| `./scripts/stop-docker.sh` | Stop and remove containers |
| `./scripts/lint-project.sh` | Lint with ruff and pyright |
| `./scripts/test-project.sh` | Run the unittest suite |
| `./scripts/coverage-project.sh` | Run tests with coverage (fails below `fail_under`; `--html` for report) |
| `./scripts/clean-project.sh` | Remove caches and build artifacts |

## Task storage

Tasks are stored under `/data/tasks/` (configurable via `TASKS_DIR` env var). The server binds `0.0.0.0` inside Docker (the compose mapping publishes `127.0.0.1` only); set `BIND_HOST=127.0.0.1` when running directly on a host.
File names follow the ``{id:03d}_{title}.md`` pattern (e.g. ``001_fix-login.md``)
for easy manual discovery.  The directory structure is:

```
/data/tasks/
├── .counter.json               # {"next_id": 5}
├── project-alpha/
│   ├── 001_fix-login.md
│   └── 003_add-auth.md
└── project-beta/
    └── 002_update-docs.md
```

The `.counter.json` file persists the next auto-incrementing ID across restarts.

## Test

### Unit tests

Run the full test suite:

```bash
cd servers/tasks-server
python3 -m unittest tests.test_server -v
```

Tests cover:
- **Endpoint whitelist** — `/tasks`, `/tasks/{id}`, `/projects`, `/ui`, `/css/*`, `/js/*` allowed, all others rejected
- **Blocked endpoints** — root, health checks, arbitrary paths, non-numeric task IDs
- **Frontmatter parsing** — scalars, arrays, nulls, roundtrip; writer-escaped newlines/quotes and hand-written legacy forms
- **Task CRUD** — create, read, update (incl. project moves), delete, auto-increment IDs
- **Project management** — listing, creation, name validation (traversal refusal at every entry point)
- **Query filtering** — `?project=`, `?status=`, combined filters, 400 on an unsafe project filter
- **Counter persistence** — survives across get/create calls
- **Request validation** — non-object JSON bodies, wrong field types, `due_date` format, clamped long titles, non-numeric and negative `Content-Length`
- **Odd task files** — missing frontmatter keys backfilled, unreadable files (non-UTF-8, directories, dangling symlinks) skipped without dropping the request
- **Static serving** — path-traversal containment, directory 404s, query strings stripped, HEAD mirrors GET
- **UI escaping** — attribute contexts use the quote-escaping encoder, inline-JS args are JSON-encoded, markdown links carry a scheme allowlist
- **HTTP handler** — all endpoints, error responses (400, 404, 405)
- **Logging** — format, timestamp, client IP
- **Graceful shutdown** — signal handlers
- **Handler methods** — GET, HEAD, POST, PATCH, DELETE, PUT exist

### Manual test

```bash
# List all tasks (should return empty list)
curl http://localhost:8088/tasks

# Create a task
curl -X POST http://localhost:8088/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"Test task","project":"demo","priority":"medium"}'

# Get the task
curl http://localhost:8088/tasks/1

# Update the task
curl -X PATCH http://localhost:8088/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{"status":"closed"}'

# List tasks with filter
curl "http://localhost:8088/tasks?project=demo&status=open"

# List projects
curl http://localhost:8088/projects

# Delete the task
curl -X DELETE http://localhost:8088/tasks/1

# Missing title (should return 400)
curl -X POST http://localhost:8088/tasks \
  -H "Content-Type: application/json" \
  -d '{"project":"demo"}'

# Unknown endpoint (should return 404)
curl http://localhost:8088/unknown
```

## Agent Skills

One skill file is included so an agent can use the server directly. It teaches the agent to call the server via `curl` to `localhost:8088` — no credentials or storage management needed.

### Docker networking (auto-detection)

When the agent runs inside a Docker container, `localhost` points to the container itself, not the host. All skill files include an auto-detection snippet that checks for `.dockerenv` and cgroup markers, then sets `PROXY` to `http://host.docker.internal:8088` when appropriate.

If you use a custom setup (e.g., WSL2, VM-based containers), you may need to adjust the detection logic or set `PROXY` manually.

### `skills/tasks-server/tasks-server/SKILL.md`

Full agent skill for managing tasks:

- **List tasks** — `GET /tasks` with optional `?project=` and `?status=` filters
- **Get task** — `GET /tasks/{id}`
- **Create task** — `POST /tasks` with title, project, priority, due_date, tags, description
- **Update task** — `PATCH /tasks/{id}` for partial updates
- **Delete task** — `DELETE /tasks/{id}`
- **List projects** — `GET /projects`
- **Create project** — `POST /projects` with a project name

### Using the skills in harnesses

To make the skills available to an agent, copy the skill directory into the agent's skills path, `~/.pi/agent/skills/`, preserving the feature subfolder. Run these **from the repository root** (`cd "$(git rev-parse --show-toplevel)"` — not from `servers/tasks-server/`, where this README lives):

```bash
# copy the tasks-server skill (from the repo root)
mkdir -p ~/.pi/agent/skills/tasks-server
cp -r skills/tasks-server/tasks-server ~/.pi/agent/skills/tasks-server/
```

The skill will then be automatically discovered by the agent on every conversation. To verify it loaded:

```bash
ls ~/.pi/agent/skills/tasks-server/tasks-server/SKILL.md
```

If you keep this repo's skills elsewhere, symlink the feature folder instead (works from any directory — `git rev-parse` resolves the repo root):

```bash
ln -s "$(git rev-parse --show-toplevel)/skills/tasks-server" ~/.pi/agent/skills/tasks-server
```
