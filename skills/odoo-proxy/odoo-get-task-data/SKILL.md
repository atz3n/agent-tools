---
name: odoo-get-task-data
description: Call the Odoo proxy server via REST API to read task fields through the local proxy on port 8087.
---

This skill provides instructions for calling the Odoo task proxy server directly via REST API. The proxy runs on `localhost:8087` and manages Odoo authentication internally — no credentials needed.

## Network Note

Agents may run inside a Docker container where `localhost` points to the container itself, not the host. Detect your environment and set `PROXY` automatically:

```bash
if [ -f /.dockerenv ] || grep -qE 'docker|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
  PROXY="http://host.docker.internal:8087"
else
  PROXY="http://localhost:8087"
fi
```

## Verify Proxy is Running

```bash
curl -s $PROXY/task/data?id=1 || echo "Proxy not running or not configured"
```

## How to Call the Proxy

The proxy speaks JSON over HTTP. Use `curl` directly:

```bash
curl -s "$PROXY/task/data?id=123" | jq '.'
```

**Tip:** Save the base URL to avoid repetition:

```bash
PROXY="http://localhost:8087"
```

## Read Task Fields

Reads task fields via `project.task.web_read` RPC. Requires `id` parameter (integer task ID).

```bash
curl -s "$PROXY/task/data?id=123" | jq '.'
```

### Response

Returns a JSON object with a `task` key containing the task fields:

```bash
curl -s "$PROXY/task/data?id=123" | jq '.task'
```

Key fields included in the response:

| Field | Description |
|-------|-------------|
| `id` | Task ID |
| `name` | Task title |
| `display_name` | Display name |
| `description` | HTML description |
| `priority` | Priority (`0`–`4`, `4` = highest) |
| `state` | Current stage code |
| `stage_id` | Stage object with `display_name` |
| `project_id` | Project object with `display_name` |
| `partner_id` | Partner/customer object |
| `user_ids` | Array of assigned users |
| `date_deadline` | Deadline datetime |
| `planned_date_begin` | Planned start datetime |
| `progress` | Progress percentage |
| `remaining_hours` | Remaining hours |
| `effective_hours` | Effective hours worked |
| `total_hours_spent` | Total hours spent |
| `tag_ids` | Array of tags with `display_name` and `color` |
| `company_id` | Company object |
| `rating_count` | Number of ratings |
| `rating_avg` | Average rating |
| `subtask_count` | Number of subtasks |
| `dependent_tasks_count` | Number of dependent tasks |

### Error Responses

- `400` — Missing or invalid `id` parameter
- `404` — Endpoint not found (non-whitelisted path)
- `502` — Odoo backend unreachable or session error

```bash
# Check for errors
curl -s -w "\nHTTP_CODE: %{http_code}" "$PROXY/task/data?id=invalid"
```

## Extract Common Fields

```bash
# Task name
curl -s "$PROXY/task/data?id=123" | jq '.task.name'

# Priority
curl -s "$PROXY/task/data?id=123" | jq '.task.priority'

# Stage name
curl -s "$PROXY/task/data?id=123" | jq '.task.stage_id.display_name'

# Assigned users
curl -s "$PROXY/task/data?id=123" | jq '.task.user_ids[].display_name'

# Deadline
curl -s "$PROXY/task/data?id=123" | jq '.task.date_deadline'

# Progress
curl -s "$PROXY/task/data?id=123" | jq '.task.progress'

# Description
curl -s "$PROXY/task/data?id=123" | jq '.task.description'
```
