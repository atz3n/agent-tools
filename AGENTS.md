# agent-tools

A repository of lightweight proxy servers, agent skills, and templates for AI agents. It contains four Dockerized services (GitHub API proxy, Odoo task proxy, tasks server, LLM inference proxy), a wiki template, and agent skills.

---

## Conventions

- KISS, DRY, YAGNI — prefer the smallest elegant solution; no speculative abstractions, no unused knobs.
- Stdlib-only for servers; no external dependencies unless truly necessary.
- No unnecessary comments. Code should be self-documenting; comment only non-obvious intent.

---

## Project Overview

This repo provides **agent-facing tools** — small, focused services that expose a subset of external APIs through a local proxy. Each proxy runs in Docker, enforces an endpoint whitelist, and injects credentials internally so agents never handle secrets directly.

### Components

| Component | Port | Purpose |
|-----------|------|---------|
| **github-proxy** | 8086 | Reverse proxy for GitHub REST API, restricted to PR/review/issue endpoints only. Injects a PAT from `secrets/`. |
| **odoo-proxy** | 8087 | Application server for Odoo task data. Manages an Odoo login session internally and exposes `/task/data`, `/task/messages`, and `/task/message`. |
| **tasks-server** | 8088 | REST API for managing tasks stored as markdown files with YAML frontmatter. Includes a zero-dependency web UI. |
| **llm-proxy** | 8089 | Credential-injecting reverse proxy for LLM inference. One host:port, one path prefix per provider (`/openrouter` → openrouter.ai, `/mlx-serve` → local OpenAI-compatible server), per-route endpoint whitelist, optional model allowlist and client token gate, unbuffered SSE passthrough. Format pass-through only — no dialect translation; model selection stays in the agent. |
| **skills/** | — | Agent skill markdown files organized by feature. |
| **templates/llm-wiki/** | — | Template for LLM-assisted knowledge bases (idea file + format spec + init prompt). |
| **harnesses/** | — | Isolated agent runtimes — currently `pia`: Pi agent harness with Docker setup and `pia` multi-instance manager.

### Architecture

```
Agent → curl → localhost:8086 (github-proxy)  → api.github.com
Agent → curl → localhost:8087 (odoo-proxy)    → Odoo instance
Agent → curl → localhost:8088 (tasks-server)  → /data/tasks/ (markdown files)
Agent → curl → localhost:8089 (llm-proxy)     → openrouter.ai / local model server
```

All four services use a package-based structure (`github_proxy/`, `odoo_proxy/`, `tasks_server/`) with separate `config.py`, `whitelist.py`, and `server.py` modules, `python:3.14-alpine` base images, and run via Docker Compose.

---

## Directory Structure

```
agent-tools/
├── servers/
│   ├── github-proxy/          # GitHub PR/issue proxy
│   │   ├── github_proxy/      # Package: config.py, whitelist.py, server.py
│   │   ├── docker/            # Dockerfile + docker-compose.yml
│   │   ├── scripts/           # build/run/pause/stop/lint/test/clean scripts
│   │   ├── secrets/           # PAT file (gitignored)
│   │   ├── tests/             # unittest test suite
│   │   ├── docs/gh-api/       # GitHub API spec
│   │   ├── pyproject.toml     # Python project config
│   │   └── README.md          # Server-specific docs
│   ├── odoo-proxy/            # Odoo task proxy
│   │   ├── odoo_proxy/        # Package: config.py, session.py, whitelist.py, server.py
│   │   ├── docker/            # Dockerfile + docker-compose.yml
│   │   ├── scripts/           # build/run/pause/stop/lint/test/clean scripts
│   │   ├── secrets/           # Credentials (gitignored)
│   │   ├── tests/             # unittest test suite
│   │   ├── spec/              # HTTP spec files (login, ticket data, messages)
│   │   ├── pyproject.toml     # Python project config
│   │   └── README.md          # Server-specific docs
│   ├── tasks-server/          # Task management REST API
│   │   ├── tasks_server/      # Package: config.py, server.py, storage.py, whitelist.py
│   │   ├── docker/            # Dockerfile + docker-compose.yml
│   │   ├── scripts/           # build/run/pause/stop/lint/test/clean scripts
│   │   ├── tests/             # unittest test suite
│   │   ├── spec/              # OpenAPI spec (openapi.yml)
│   │   ├── ui/                # Zero-dependency web UI (index.html, css/, js/)
│   │   ├── data/              # Task markdown files organized by project (gitignored)
│   │   ├── pyproject.toml     # Python project config
│   │   └── README.md          # Server-specific docs
│   ├── llm-proxy/             # LLM inference proxy (credential injection + route policy)
│   │   ├── llm_proxy/         # Package: config.py, whitelist.py (route table), server.py
│   │   ├── docker/            # Dockerfile + docker-compose.yml
│   │   ├── scripts/           # build/run/pause/stop/lint/test/clean scripts
│   │   ├── secrets/           # OpenRouter key + optional client token (gitignored)
│   │   ├── spec/              # Upstream OpenAPI specs (openrouter/)
│   │   ├── tests/             # unittest test suite
│   │   ├── pyproject.toml     # Python project config
│   │   └── README.md          # Server-specific docs
├── skills/                    # Agent skill markdown files (shared)
│   ├── git/                   # Git-related skills
│   │   ├── commit/            # Conventional commit workflow
│   │   └── commit-staged/     # Commit only already-staged changes
│   ├── github-proxy/          # GitHub proxy skills
│   │   ├── github-create-pull-request/
│   │   ├── github-manage-issues/
│   │   └── github-review-pull-request/
│   ├── odoo-proxy/            # Odoo proxy skills
│   │   ├── odoo-get-task-data/
│   │   ├── odoo-get-task-messages/
│   │   └── odoo-post-task-message/
│   ├── project/               # Project planning skills
│   │   ├── project-new-project/
│   │   ├── project-write-spec/    # SKILL.md + template.md
│   │   ├── project-architecture/
│   │   ├── project-refine/
│   │   ├── project-implement/
│   │   ├── project-help/
│   │   ├── project-doctor/        # read-only workflow consistency audit
│   │   ├── project-autopilot/     # unattended pipeline orchestration in fresh pi sessions
│   │   └── project-qa/            # SKILL.md + test-template.md
│   ├── tasks-server/          # Tasks server skills
│   │   └── tasks-server/
│   └── misc/                  # Miscellaneous utilities
│       ├── codebase-review/   # Multi-pass review.md auditor
│       ├── codebase-review-autopilot/  # review→fix→review loop in fresh pi sessions until review.md CLOSED (SKILL.md + scripts/)
│       ├── loop-prompt/       # Interviews to define task + criteria, then writes a loop prompt
│       └── incident-report/   # SKILL.md + template.md — evidence-first post-mortems with TLDR/ELI5
├── templates/
│   └── llm-wiki/              # LLM-assisted wiki template
│       ├── README.md
│       ├── spec.md
│       └── wiki.md
├── harnesses/                     # Isolated agent runtimes (harnesses)
│   └── pia/                       # Pi agent container setup and `pia` CLI
│       ├── configs/               # settings.json, cli.config.json (no models.json — the extension registers everything)
│       ├── extensions/            # llm-proxy.ts — single pi provider extension: openrouter endpoint override + dynamic mlx-serve discovery; __test__/ holds its node --test unit tests
│       ├── docker/                # image build inputs, one folder per image
│       │   ├── pia/               #   agent image: Dockerfile, entrypoint.sh, monitor-inside.sh
│       │   └── pia-dind/          #   daemon image: Dockerfile (FROM docker:29-dind), entrypoint.sh, guard.sh
│       ├── docs/                  # docker.md — how pia uses Docker (modes, guard, threat model)
│       ├── scripts/               # build-docker.sh, install-pia.sh, pia.sh, run-tests.sh
├── LICENSE
├── .gitignore
└── README.md
```

---

## Building and Running

### github-proxy

```bash
cd servers/github-proxy

# 1. Set up your PAT
echo "ghp_your_token_here" > secrets/github-personal-access-token.txt

# 2. Build and run
./scripts/build-docker.sh
./scripts/run-docker.sh

# Proxy is now at http://localhost:8086

# Stop
./scripts/stop-docker.sh
```

### odoo-proxy

```bash
cd servers/odoo-proxy

# 1. Set up credentials as files in secrets/
echo "my-db" > secrets/odoo-db.txt
echo "https://my-instance.odoo.com" > secrets/odoo-url.txt
echo "user@example.com" > secrets/odoo-user.txt
echo "password" > secrets/odoo-password.txt

# 2. Build and run
./scripts/build-docker.sh
./scripts/run-docker.sh

# Proxy is now at http://localhost:8087

# Stop
./scripts/stop-docker.sh
```

### llm-proxy

```bash
cd servers/llm-proxy

# 1. Set your OpenRouter key (optional — only the /openrouter route needs it)
echo "sk-or-v1-your-key" > secrets/openrouter-api-key.txt

# 2. Optional: shared-secret gate for all requests
echo "some-random-token" > secrets/llm-proxy-token.txt

# 3. Build and run
./scripts/build-docker.sh
./scripts/run-docker.sh

# Proxy is now at http://localhost:8089
#   POST /openrouter/v1/chat/completions  -> openrouter.ai/api/v1/... (key injected)
#   POST /mlx-serve/v1/chat/completions       -> MLX_SERVE_URL (auth stripped)

# Stop
./scripts/stop-docker.sh
```

### Testing

Each proxy has its own test suite using Python's `unittest`:

```bash
# github-proxy tests
cd servers/github-proxy
python3 -m unittest tests.test_server -v

# odoo-proxy tests
cd servers/odoo-proxy
python3 -m unittest tests.test_server -v

# tasks-server tests
cd servers/tasks-server
python3 -m unittest tests.test_server -v

# llm-proxy tests
cd servers/llm-proxy
python3 -m unittest tests.test_server -v
```

---

## tasks-server

A REST API for managing tasks stored as markdown files with YAML frontmatter. Tasks are organized in project folders with auto-incrementing IDs.

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/tasks` | List all tasks (optional `?project=`, `?status=` filters) |
| GET | `/tasks/{id}` | Get a single task by ID |
| POST | `/tasks` | Create a new task |
| PATCH | `/tasks/{id}` | Update a task (partial update) |
| DELETE | `/tasks/{id}` | Delete a task |
| GET | `/projects` | List all projects |
| POST | `/projects` | Create a new project |
| GET | `/ui` | Serve the web UI |

All other endpoints return **404 Not Found**. (The UI's static assets are served from `/css/` and `/js/`.) `HEAD` is supported on every GET path and mirrors the GET status without a body.

### Task File Format

Tasks are stored as `.md` files with YAML frontmatter:

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

### Storage

Tasks are stored under `/data/tasks/` (configurable via `TASKS_DIR` env var). File names follow the `{id:03d}_{title}.md` pattern (e.g. `001_fix-login.md`). A `.counter.json` file persists the next auto-incrementing ID across restarts (counter read/write is lock-guarded). Project names are validated as single safe path segments — anything containing `/`, `..`, or a leading dot is rejected with 400 so no request can write, move, or read task files outside `TASKS_DIR`.

### Web UI

A single-file, zero-dependency frontend is included at `ui/index.html` with separate CSS and JS files. Access it at `http://localhost:8088/ui` after starting the server. Features include search, project/status filters, task editing, create modal (with inline project creation), delete confirmation, and keyboard shortcuts (`Ctrl+K` search, `Ctrl+N` new task, `Esc` close panels).

### Getting Started

```bash
cd servers/tasks-server

# 1. Build and run
./scripts/build-docker.sh
./scripts/run-docker.sh

# Server is at http://localhost:8088
# Web UI at http://localhost:8088/ui

# Stop
./scripts/stop-docker.sh
```

### Agent Skills

The skill file (`skills/tasks-server/tasks-server/SKILL.md`) teaches the agent to call the server via `curl` to `localhost:8088`. Skills include Docker network auto-detection (`.dockerenv` / cgroup checks) to switch between `localhost` and `host.docker.internal`. Install by copying skill directories into `~/.pi/agent/skills/`, preserving the feature subfolder (e.g. `~/.pi/agent/skills/project/project-qa/`). Use the `misc/loop-prompt` skill to define and run an iterative loop prompt for task-driven agent workflows. Use the `misc/incident-report` skill to write evidence-first incident reports (TLDR + ELI5 up top, with a full and a short report tier), optionally filing them as issues via the GitHub proxy.

---

## Agent Skills

Skills are markdown files (`SKILL.md`) organized under `skills/<feature>/<name>/`. They teach agents how to call the proxies via `curl` — no MCP JSON-RPC or SSE parsing needed. Skills include Docker network auto-detection (`.dockerenv` / cgroup checks) to switch between `localhost` and `host.docker.internal`.

To install: copy skill directories into `~/.pi/agent/skills/`, preserving the feature subfolder (e.g. `~/.pi/agent/skills/project/project-qa/` — the flat layout risks skill-name shadowing).

| Feature | Skills |
|---------|--------|
| **git** | `commit`, `commit-staged` |
| **github-proxy** | `github-create-pull-request`, `github-review-pull-request`, `github-manage-issues` |
| **odoo-proxy** | `odoo-get-task-data`, `odoo-get-task-messages`, `odoo-post-task-message` |
| **project** | `project-new-project`, `project-write-spec`, `project-architecture`, `project-implement`, `project-refine`, `project-qa`, `project-help`, `project-doctor`, `project-autopilot` (unattended orchestration in fresh `pi -p` sessions on an `autopilot/*` branch) |
| **tasks-server** | `tasks-server` |
| **misc** | `codebase-review`, `codebase-review-autopilot`, `loop-prompt`, `incident-report` |

---

## llm-wiki template

The `templates/llm-wiki/` directory provides a template for LLM-assisted knowledge bases:

- **`wiki.md`** — Karpathy's idea file describing the personal-wiki concept
- **`spec.md`** — Google's OKF specification for a standardized wiki format
- **`README.md`** — initialization prompt and usage instructions

To use: copy the template into a project and run the initialization prompt from its README.

---

## Development Conventions

### Server Implementation

- **Package-based structure**: Each proxy is a Python package (`github_proxy/`, `odoo_proxy/`, `tasks_server/`) with separate modules: `config.py` (configuration and logging), `whitelist.py` (endpoint patterns), and `server.py` (HTTP handler). The odoo-proxy also has `session.py` for Odoo session management. The tasks-server has `storage.py` for markdown file CRUD operations.
- **No external dependencies**: All code uses only Python stdlib (`http.server`, `json`, `re`, `os`, `signal`, `http.client`, `urllib.parse`, etc.).
- **Endpoint whitelisting**: All services use compiled regex patterns to whitelist allowed paths. Non-matching paths return 404 with a uniform `{"error": "..."}` body in all four services; 405 for a whitelisted path with an unsupported method (odoo-proxy, tasks-server, llm-proxy; github-proxy forwards every method it implements, including HEAD). OPTIONS and TRACE are unimplemented everywhere and return 501 from the HTTP layer (no proxy log line).
- **Configuration via env vars**: `PROXY_PORT`, `BIND_HOST` (all four), `GITHUB_PERSONAL_ACCESS_TOKEN` (github-proxy), `ODOO_DB`, `ODOO_URL`, `ODOO_USER`, `ODOO_PASSWORD`, `ODOO_SESSION_TIMEOUT` (odoo-proxy), `TASKS_DIR` (tasks-server), `OPENROUTER_API_KEY`, `MLX_SERVE_URL`, `LLM_PROXY_TOKEN`, `ALLOWED_MODELS`, `LLM_UPSTREAM_TIMEOUT` (llm-proxy). Credentials are loaded from `secrets/` files by the Docker scripts and passed as env vars.
- **Graceful shutdown**: All servers register SIGTERM/SIGINT handlers; the handler dispatches `server.shutdown()` to a short-lived background thread (calling it on the signal handler's own thread deadlocks against `serve_forever()`), and all four run `ThreadingHTTPServer` with `daemon_threads` so concurrent clients never head-of-line-block and in-flight requests can't block shutdown.
- **Logging**: All requests log to `stderr` in format `[proxy] <ISO-8601> <METHOD> <PATH> <STATUS> from <IP>`.

### Docker

- All four services use `python:3.14-alpine` base images.
- Docker Compose files bind to `127.0.0.1` to avoid exposing ports to the host network.
- Build scripts use `docker compose -p <project-name>` for project-scoped container naming.
- Each server has scripts for: `build-docker.sh`, `run-docker.sh`, `pause-docker.sh` (compose `stop` — stops without removing), `stop-docker.sh`, `lint-project.sh`, `test-project.sh`, `coverage-project.sh`, `clean-project.sh`.

### Tests

- Tests use `unittest` with `unittest.mock` for patching.
- Tests cover: endpoint whitelist (allowed + blocked paths), query parameter handling, configuration loading, credential loading (env vars validated at startup), logging format, HTTP method support, session management (odoo-proxy), graceful shutdown, frontmatter parsing, task CRUD, project management (list, create), counter persistence, handler methods (tasks-server), route resolution, prefix stripping, credential injection/stripping, model allowlist, token gate, SSE passthrough, and 502 handling (llm-proxy).
- Tests import the server module directly (tasks-server prepends `sys.path`; the others import through the package directory/cwd) — no actual server is started.

### Code Quality

- All servers use `ruff` for linting (see `pyproject.toml`) and `pyright` for type checking.
- Run `./scripts/lint-project.sh` in each server directory.

---

## harnesses/pia — Pi Harness

A containerized [Pi Coding Agent](https://pi.dev) for isolated, interactive operation — like talking to an agent in your terminal. Full documentation: [harnesses/pia/README.md](harnesses/pia/README.md).

### Building

```bash
cd harnesses/pia
bash scripts/build-docker.sh
```

The Docker image includes the Pi Coding Agent, Playwright CLI with browser support, and agent skills. It also installs `harnesses/pia/extensions/llm-proxy.ts` into `~/.pi/agent/extensions/` — a single pi provider extension that registers all inference wiring: the `openrouter` built-in endpoint override (proxy `/openrouter/v1` route, built-in catalog preserved) and the `mlx-serve` native dynamic provider (`GET /mlx-serve/v1/models` discovery, issue #14) — so the image ships **no models.json**; `LLM_PROXY_URL` and the optional `LLM_PROXY_TOKEN` gate are the only config. Unit tests: `node --test harnesses/pia/extensions/__test__/`. The build context is the repository root, so all `COPY` paths in the Dockerfile are relative to that.

### `pia` CLI — Multi-Instance Manager

The `pia` CLI lets you run multiple Pi agent containers in parallel, each with its own name.

| Command | Description |
|---------|-------------|
| `pia run [NAME]` | Start a new agent container (auto-names if omitted) |
| `pia create [NAME] [OPTIONS]` | Create a stopped container without starting it (same options as `pia run`; for later use with `pia ask`) |
| `pia run -m /path` | Start with `/path` mounted into `/workspace` |
| `pia run --ssh` | Start with host SSH agent socket mounted |
| `pia run --docker` | Start with a private throwaway sibling Docker daemon (`NAME-dind`, no host socket/mounts; sysbox/gVisor runtime auto-detected, privileged fallback on plain runc). The daemon runs the built `pia-dind:guard-v<N>` image (FROM digest-pinned `docker:29-dind`) with a nested-container guard (`pia-dind-guard`, baked in and installed as its runc) refusing privileged/capped/container-internal-bind workloads. `--docker-dev` additionally mounts the `-m` workspace into that daemon at the same path, so nested bind mounts and compose configs resolve (one directory only). `--docker-full` mounts the raw host socket instead — host-root-equivalent, loud banner, refused by `pia ask` |
| `pia stop [NAME]` | Stop a named container |
| `pia remove [NAME]` / `pia rm [NAME]` | Stop and remove a named container |
| `pia list` / `pia ls` | List all agent containers |
| `pia clean` | Remove all stopped agent containers (kept `pia-keep-*` containers are never removed) |
| `pia keep [NAME] [SUFFIX]` | Protect a container from `pia clean` (renames it to `pia-keep-*`) |
| `pia unkeep [NAME]` | Remove the keep protection (renames it back to `pia-*`) |
| `pia rename [NAME] [NEW]` | Rename a container (running or stopped) |
| `pia resume` / `pia rs` | Start the latest stopped container and continue its last pi session |
| `pia ask [NAME] <prompt>` | One-shot non-interactive pi prompt (`pi --print`); omit NAME for an ephemeral container |
| `pia restart [NAME] [OPTIONS]` | Restart a named container, continuing its last pi session — unchanged/omitted flags resume in place; changed flags re-create but carry the pi conversation over (`pi --continue`); `--fresh` forces recreate + clean session |
| `pia exec [NAME] [CMD]` | Execute a command in a running container |
| `pia sh [NAME]` / `pia shell [NAME]` | Open an interactive bash shell in a running container (omit NAME if only one runs) |
| `pia monitor [NAME]` | Live view of the container's request destinations (TLS SNI / cleartext HTTP URLs) plus CPU, memory and net I/O — drawn as charts on a terminal (sparklines, a memory gauge, a ranked destination pane), one line per sample when piped. Terminal only, the monitor itself logs nothing (`--raw` streams destinations only, `--no-chart` forces the line view, `--chart` forces the dashboard) |
| `pia urls [NAME]` | Every destination/URL the container has called since its creation, with counts — the entrypoint keeps a `tshark` request log (`/var/log/pia-urls.log`) for the container's whole life; `--all` prints every logged request |
| `pia dindlog [NAME]` | Nested-container guard refusals of the agent's throwaway Docker daemon — the reasons behind opaque `runc did not terminate successfully` errors; works even after a guard kill-switch exit (reads the log from the container layer) |

Containers are grouped under the `pia` project by plain `docker --label` stamping (`com.docker.compose.project=pia`, plus a per-container `config-hash` that project views require) — compose is never called and no compose file is used, so `docker ps --filter label=com.docker.compose.project=pia` and Docker Desktop show all agent instances as one project. Containers are named with the `pia-` prefix. If no `NAME` is provided, a random name is generated (e.g., `pia-k3m9x2p1`). Install the CLI globally with `bash harnesses/pia/scripts/install-pia.sh`. The test suite supports filtering to specific commands via `bash harnesses/pia/scripts/run-tests.sh run stop` to skip slow Docker-based tests; the provider-extension unit tests (`extensions/__test__/`, node-based, no Docker) run in every full run and can be selected alone with `run-tests.sh extensions`.

---

## Key Technical Details

### github-proxy

- **Whitelist**: 29 regex patterns covering PR CRUD, reviews, review comments (incl. comment-scoped get/update/delete at `/pulls/comments/{id}`, plus replies and reactions), review reactions, merge, commits, files, requested reviewers (list/add/remove via `/pulls/{n}/requested_reviewers`, with the hyphenated `requested-reviewers` alias auto-normalized), issue CRUD, issue comments (incl. comment-scoped get/update/delete at `/issues/comments/{id}`), issue labels/assignees, repository labels, and `/user`.
- **Auth**: Bearer token injected from `GITHUB_PERSONAL_ACCESS_TOKEN` env var.
- **Headers**: Combines duplicate `Accept` headers, strips hop-by-hop headers (`Connection`, `Keep-Alive`, `Transfer-Encoding`), sets `User-Agent: pr-proxy/1.0`.
- **Network skill**: Auto-detects Docker environment and sets `PROXY` to `host.docker.internal:8086` when running inside a container.

### odoo-proxy

- **Session management**: Two-step Odoo login (GET `/web/login` for CSRF token → POST with credentials). Session cookies are persisted and refreshed on expiry (45 min default, configurable via `ODOO_SESSION_TIMEOUT`).
- **RPC**: Uses Odoo's `/web/dataset/call_kw` JSON-RPC endpoint for `project.task.web_read` and `/mail/thread/messages` for fetching messages; notes are posted through Odoo's dedicated `/mail/message/post` route (call_kw cannot record-target `message_post` — `body` is its first positional parameter).
- **Configuration**: Reads 4 environment variables (`ODOO_DB`, `ODOO_URL`, `ODOO_USER`, `ODOO_PASSWORD`), which are loaded from `secrets/` files by the Docker scripts. Validates all exist at startup.
- **Endpoints**: Only `/task/data?id=<task_id>`, `/task/messages?id=<id>`, and `/task/message?id=<id>` (POST) are allowed. All others return 404.

### tasks-server

- **Storage**: Tasks stored as `.md` files with YAML frontmatter under `/data/tasks/` (configurable via `TASKS_DIR`). File names follow `{id:03d}_{title}.md` pattern.
- **Auto-increment IDs**: `.counter.json` persists the next ID across restarts.
- **Filtering**: `GET /tasks` supports `?project=` and `?status=` query parameters for filtering.
- **Partial updates**: `PATCH /tasks/{id}` merges provided fields into existing task.
- **Project creation**: `POST /projects` creates a new project directory.
- **Web UI**: Zero-dependency `ui/index.html` served at `/ui` — search, filters, task editing, create modal with inline project creation, delete confirmation, keyboard shortcuts.

### llm-proxy

- **Route table**: `whitelist.py` defines `Route` entries (prefix → target + `(method, path)` whitelist + optional path aliases). The prefix is stripped and aliases applied before forwarding — the public `/openrouter/v1/chat/completions` is rewritten to openrouter.ai's `/api/v1/chat/completions`, while `/mlx-serve` passes through unchanged; unknown prefixes 404, whitelisted paths with the wrong method 405.
- **No translation**: requests/responses pass through byte-for-byte in the provider's native dialect; SSE (`text/event-stream`) responses are copied chunk-by-chunk with a flush per chunk. The proxy never rewrites model ids or picks models — that stays in the agent.
- **Credential handling**: the OpenRouter key is injected as a Bearer token (client `Authorization` overridden); for credential-free routes (mlx-serve) client auth is stripped. A route with missing credentials is disabled (404) rather than failing at startup.
- **Policy**: optional `ALLOWED_MODELS` list polices the `model` field of completion bodies — both `/chat/completions` and `/messages` dialects, on every route (403 if not listed; 400 if the list is set but the body carries no parsable model); optional `LLM_PROXY_TOKEN` gates all requests with `Authorization: Bearer <token>` (401 otherwise, constant-time compare) so other host processes can't ride the proxy.
- **HTTP/1.0 responses**: `Transfer-Encoding` is stripped, so connection close is what signals end-of-body for streamed responses; `ThreadingHTTPServer` with daemon threads (all four services) keeps concurrent sessions independent of shutdown.

---

## Version Control

- **Do not auto-commit.** Only commit changes when the user explicitly requests it.
- Never push to a remote without an explicit request.

## Security Notes

- The github-proxy PAT is stored as a file in `secrets/` (gitignored) and injected as a Bearer token — agents never see it.
- The odoo-proxy credentials are stored as files in `secrets/` (gitignored) and injected into backend requests internally — agents never see them.
- The tasks-server has no secrets; it writes task files to a local volume (`/data/tasks/`).
- The llm-proxy OpenRouter key is stored as a file in `secrets/` (gitignored) and injected into backend requests internally — agent containers configured against the proxy never hold a provider key. The proxy is intentionally unauthenticated by default (localhost-only publish, single-user host, agents you control); pair it with a dedicated openrouter key carrying a small per-key spend limit, and set `LLM_PROXY_TOKEN` before the host is shared or the port is reachable beyond localhost.
- All proxies reject non-whitelisted endpoints, minimizing the attack surface.
