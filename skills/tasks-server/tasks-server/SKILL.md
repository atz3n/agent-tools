---
name: tasks-server
description: Call the tasks server REST API to manage tasks stored as markdown files through the local proxy on port 8088.
---

This skill provides instructions for calling the tasks server directly via REST API. The server runs on `localhost:8088` and manages tasks stored as markdown files with YAML frontmatter — no credentials needed.

## Network Note

Agents may run inside a Docker container where `localhost` points to the container itself, not the host. Detect your environment and set `PROXY` automatically:

```bash
if [ -f /.dockerenv ] || grep -qE 'docker|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
  PROXY="http://host.docker.internal:8088"
else
  PROXY="http://localhost:8088"
fi
```

## Verify Proxy is Running

```bash
curl -s $PROXY/projects || echo "Proxy not running or not configured"
```

## How to Call the Proxy

The proxy speaks JSON over HTTP. Use `curl` directly:

```bash
curl -s "$PROXY/projects" | jq '.'
```

**Tip:** Save the base URL to avoid repetition:

```bash
PROXY="http://localhost:8088"
```

## List Tasks

Returns all tasks, optionally filtered by `?project=` and `?status=`.

```bash
# List all tasks
curl -s "$PROXY/tasks" | jq '.tasks[]'

# Filter by project
curl -s "$PROXY/tasks?project=demo" | jq '.tasks[]'

# Filter by status
curl -s "$PROXY/tasks?status=open" | jq '.tasks[]'

# Filter by both
curl -s "$PROXY/tasks?project=demo&status=open" | jq '.tasks[]'
```

### Response

Returns a JSON object with `tasks` array and `count`:

```json
{
  "tasks": [
    {
      "id": 1,
      "title": "Fix login bug",
      "status": "open",
      "priority": "high",
      "due_date": "2026-08-15",
      "tags": ["bug", "auth"],
      "created_at": "2026-07-27T10:00:00Z",
      "updated_at": "2026-07-27T10:00:00Z",
      "description": "The login form does not submit...",
      "project": "demo"
    }
  ],
  "count": 1
}
```

## Get Task by ID

```bash
curl -s "$PROXY/tasks/1" | jq '.task'
```

Returns a single task object or 404 if not found.

## Create Task

```bash
curl -s -X POST "$PROXY/tasks" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "New feature",
    "project": "demo",
    "priority": "medium",
    "due_date": "2026-09-01",
    "tags": ["feature", "frontend"],
    "description": "Implement the new dashboard"
  }' | jq '.task'
```

### Default values

When creating a task, use the following defaults unless the user specifies otherwise:

- **priority**: `medium`
- **status**: `open`
- **due_date**: `null` (empty)

Only set these fields to different values when the user explicitly requests it.

### Required fields

- `title` (string) — task title

### Optional fields

- `project` (string) — project folder name (default: "default")
- `status` (string) — task status (default: "open")
- `priority` (string) — priority level (default: "medium")
- `due_date` (string) — ISO date or null
- `tags` (array) — list of tag strings
- `description` (string) — task description

Returns the created task with auto-assigned `id` and timestamps.

## Update Task (PATCH)

```bash
curl -s -X PATCH "$PROXY/tasks/1" \
  -H "Content-Type: application/json" \
  -d '{"status": "closed"}' | jq '.task'
```

Partial update — only include the fields you want to change. Returns the updated task or 404.

## Delete Task

```bash
curl -s -X DELETE "$PROXY/tasks/1" | jq '.'
```

Returns `{"deleted": true, "id": 1}` on success, or 404 if not found.

## List Projects

```bash
curl -s "$PROXY/projects" | jq '.'
```

Returns all project directories (folders containing task files):

```json
{
  "projects": ["alpha", "beta", "demo"],
  "count": 3
}
```

## Create Project

Create a project folder before assigning tasks to it (tasks can also auto-create their project on POST):

```bash
curl -s -X POST "$PROXY/projects" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-project"}'
```

Returns `{"project": "my-project"}` with status 201. Missing or empty `name` returns 400.

## Error Responses

- `400` — Missing required fields, invalid JSON
- `404` — Task not found, endpoint not found
- `405` — HTTP method not allowed

```bash
# Check for errors
curl -s -w "\nHTTP_CODE: %{http_code}" "$PROXY/tasks"
```
