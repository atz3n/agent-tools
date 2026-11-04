# Odoo Proxy

A lightweight application server that exposes task (project task) information from an Odoo instance. Manages the Odoo authentication session internally and exposes simple REST endpoints.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/task/data?id=<task_id>` | Task fields via `project.task.web_read` |
| GET | `/task/messages?id=<id>` | Thread messages via `mail.thread.messages` |
| POST | `/task/message?id=<id>` | Post a note to a thread via `project.task.message_post` |

All other endpoints return **404 Not Found**.

> **Note:** Only the HTTP methods listed in the table above are supported (GET, POST). Other methods return 405 Method Not Allowed.

## Architecture

```
Client → :8087 (proxy) → Odoo instance
         ↑ session mgmt  exposes task endpoints only
         credentials from secrets/
```

## Getting started

1. Place your Odoo credentials in `./secrets/`:
   - `odoo-db.txt` — database name (e.g. `my-odoo`)
   - `odoo-url.txt` — Odoo.sh URL (e.g. `https://my-odoo.odoo.com`)
   - `odoo-user.txt` — login email
   - `odoo-password.txt` — password

2. Build the proxy image: `./scripts/build-docker.sh`

3. Run the containers: `./scripts/run-docker.sh`

The proxy is reachable at `http://localhost:8087`.

## Docker scripts

| Script | Description |
|--------|-------------|
| `./scripts/build-docker.sh` | Build the proxy image |
| `./scripts/run-docker.sh` | Start the containers (validates secrets exist) |
| `./scripts/pause-docker.sh` | Pause without removing containers |
| `./scripts/stop-docker.sh` | Stop and remove containers |
| `./scripts/lint-project.sh` | Lint with ruff and pyright |
| `./scripts/test-project.sh` | Run the unittest suite |
| `./scripts/clean-project.sh` | Remove caches and build artifacts |

## Credential management

The credentials are stored as individual files in `./secrets/` (`odoo-db.txt`, `odoo-url.txt`, `odoo-user.txt`, `odoo-password.txt`). The `run-docker.sh` script reads these files and passes them as environment variables to the container.

The proxy manages its Odoo login session internally and refreshes it when it expires. The session lifetime defaults to 45 minutes and can be changed via the `ODOO_SESSION_TIMEOUT` environment variable (seconds).

To rotate credentials:

1. Update the relevant file(s) in `./secrets/`
2. Restart: `./scripts/stop-docker.sh && ./scripts/run-docker.sh`

## Test

### Unit tests

Run the full test suite:

```bash
cd servers/odoo-proxy
python3 -m unittest tests.test_server -v
```

Tests cover:
- **Endpoint whitelist** — `/task/data`, `/task/messages`, `/task/message` allowed, all others rejected
- **Blocked endpoints** — `/web/login`, `/web/dataset/*`, `/mail/thread/*`, `/mail/message_post`, root, health checks, etc.
- **Query parameter handling** — `?id=3807` parsing, empty query strings
- **Configuration** — port (hardcoded in docker-compose.yml), env var overrides
- **Credential loading** — env var reading, missing var handling
- **Logging** — format, timestamp, client IP
- **Session management** — expiry detection, timeout
- **HTTP method handling** — GET, POST, PATCH, PUT, DELETE exist
- **Graceful shutdown** — signal handlers
- **POST /task/message handler** — success, missing id, invalid id, missing body, invalid JSON, 502 errors

### Manual test

```bash
# Get task data (should return 200 with task fields)
curl "http://localhost:8087/task/data?id=3807"

# Get task messages (should return 200 with messages array)
curl "http://localhost:8087/task/messages?id=3807"

# Post a message to a task thread (should return 200 with posted message)
curl -X POST "http://localhost:8087/task/message?id=3807" \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello from curl"}'

# Missing id parameter (should return 400)
curl "http://localhost:8087/task/data"

# Unknown endpoint (should return 404)
curl "http://localhost:8087/unknown"
```

## Agent Skills

Three skill files are included so an agent can use the proxy directly. All teach the agent to call the proxy via `curl` to `localhost:8087` — no Odoo credentials or session management needed.

### Docker networking (auto-detection)

When the agent runs inside a Docker container, `localhost` points to the container itself, not the host. All skill files include an auto-detection snippet that checks for `.dockerenv` and cgroup markers, then sets `PROXY` to `http://host.docker.internal:8087` when appropriate.

If you use a custom setup (e.g., WSL2, VM-based containers), you may need to adjust the detection logic or set `PROXY` manually.

### `skills/odoo-proxy/odoo-get-task-data/SKILL.md`

For reading task fields:

- **Read task fields** — `GET /task/data?id=<task_id>` via `project.task.web_read`
- **Extract common fields** — name, priority, stage, users, deadline, progress, description

### `skills/odoo-proxy/odoo-get-task-messages/SKILL.md`

For reading thread messages:

- **Read thread messages** — `GET /task/messages?id=<id>` via `mail.thread.messages`
- **Filter and iterate** — comments only, messages with attachments, message listing

### `skills/odoo-proxy/odoo-post-task-message/SKILL.md`

For posting messages to a task thread:

- **Post a note** — `POST /task/message?id=<id>` via `project.task.message_post`
- **Simple format** — `{ "body": "..." }` with optional `message_type` and `subtype_xmlid`
- **Message types** — internal notes, public messages, email notifications

### Using the skills in harnesses

To make the skills available to an agent, copy the skill directories into the agent's skills path, `~/.pi/agent/skills/`, preserving the feature subfolder:

```bash
# copy odoo skills
mkdir -p ~/.pi/agent/skills/odoo-proxy
cp -r skills/odoo-proxy/odoo-get-task-data ~/.pi/agent/skills/odoo-proxy/
cp -r skills/odoo-proxy/odoo-get-task-messages ~/.pi/agent/skills/odoo-proxy/
cp -r skills/odoo-proxy/odoo-post-task-message ~/.pi/agent/skills/odoo-proxy/
```

The skills will then be automatically discovered by the agent on every conversation. To verify they loaded:

```bash
ls ~/.pi/agent/skills/odoo-proxy/odoo-get-task-data/SKILL.md
ls ~/.pi/agent/skills/odoo-proxy/odoo-get-task-messages/SKILL.md
ls ~/.pi/agent/skills/odoo-proxy/odoo-post-task-message/SKILL.md
```

If you keep this repo's skills elsewhere, symlink the feature folder instead:

```bash
ln -s "$(pwd)/skills/odoo-proxy" ~/.pi/agent/skills/odoo-proxy
```
