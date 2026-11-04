---
name: github-manage-issues
description: Call the GitHub PR proxy server via REST API to list, create, get, update, comment on, label, and assign issues through the local proxy on port 8086.
---

This skill provides instructions for calling the GitHub proxy server directly via REST API. The proxy runs on `localhost:8086` and injects your PAT automatically — no authentication header needed.

## Network Note

Agents may run inside a Docker container where `localhost` points to the container itself, not the host. Detect your environment and set `PROXY` automatically:

```bash
if [ -f /.dockerenv ] || grep -qE 'docker|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
  PROXY="http://host.docker.internal:8086"
else
  PROXY="http://localhost:8086"
fi
```

## Verify Proxy is Running

Before making issue calls, confirm the proxy is up and your credentials are configured:

```bash
curl -s $PROXY/user || echo "Proxy not running or not configured"
```

## How to Call the Proxy

The proxy speaks standard GitHub REST API over HTTP. Use `curl` directly:

```bash
curl -s $PROXY/repos/{owner}/{repo}/issues
```

For POST/PATCH/PUT/DELETE with a body:

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/issues \
  -H "Content-Type: application/json" \
  -d '{"title":"My issue","body":"Description"}'
```

**Tip:** Save the base URL to avoid repetition:

```bash
PROXY="http://localhost:8086"
```

## Get Your GitHub Username

Required to resolve `{owner}` in all issue endpoints:

```bash
curl -s $PROXY/user | jq '.login'
```

## List Issues

```bash
curl -s "$PROXY/repos/{owner}/{repo}/issues?state=open&sort=created&direction=desc" | jq '.'
```

Query params: `state` (`open`, `closed`, `all`), `labels` (comma-separated), `sort` (`created`, `updated`, `comments`), `direction` (`asc`, `desc`), `per_page`, `page`.

> **Note:** GitHub returns pull requests in the issues list too. Filter out entries that have a `pull_request` field:
>
> ```bash
> curl -s "$PROXY/repos/{owner}/{repo}/issues" | jq '[.[] | select(has("pull_request") | not)]'
> ```

## Create an Issue

Required params: `title`

Optional params: `body`, `assignees` (array), `labels` (array), `milestone`

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/issues \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Login form does not submit",
    "body": "Steps to reproduce:\n1. ...\n2. ...",
    "labels": ["bug"]
  }' | jq '.number'
```

The response includes `number` — use it for all subsequent issue operations.

## Get an Issue

```bash
curl -s $PROXY/repos/{owner}/{repo}/issues/42 | jq '.'
```

## Update / Close an Issue

GitHub has **no DELETE endpoint for issues** — "deleting" means closing:

```bash
curl -s -X PATCH $PROXY/repos/{owner}/{repo}/issues/42 \
  -H "Content-Type: application/json" \
  -d '{"state":"closed"}' | jq '.'
```

Fields: `title`, `body`, `state` (`open`/`closed`), `assignees`, `labels`, `milestone`.

## List Issue Comments

```bash
curl -s "$PROXY/repos/{owner}/{repo}/issues/42/comments" | jq '.'
```

## Create an Issue Comment

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/issues/42/comments \
  -H "Content-Type: application/json" \
  -d '{"body":"Looks like a race condition in the submit handler."}' | jq '.html_url'
```

## Get / Update / Delete an Issue Comment

```bash
# Get
curl -s $PROXY/repos/{owner}/{repo}/issues/42/comments/123 | jq '.'

# Update
curl -s -X PATCH $PROXY/repos/{owner}/{repo}/issues/42/comments/123 \
  -H "Content-Type: application/json" \
  -d '{"body":"Updated comment body"}' | jq '.'

# Delete (returns 204)
curl -s -o /dev/null -w "%{http_code}" -X DELETE $PROXY/repos/{owner}/{repo}/issues/42/comments/123
```

## Labels on an Issue

```bash
# List labels on an issue
curl -s $PROXY/repos/{owner}/{repo}/issues/42/labels | jq '.[].name'

# Add labels (keeps existing ones)
curl -s -X POST $PROXY/repos/{owner}/{repo}/issues/42/labels \
  -H "Content-Type: application/json" \
  -d '{"labels":["bug","priority:high"]}' | jq '.[].name'

# Replace all labels
curl -s -X PUT $PROXY/repos/{owner}/{repo}/issues/42/labels \
  -H "Content-Type: application/json" \
  -d '{"labels":["needs-triage"]}' | jq '.[].name'

# Remove one label
curl -s -o /dev/null -w "%{http_code}" -X DELETE $PROXY/repos/{owner}/{repo}/issues/42/labels/bug

# Remove all labels
curl -s -o /dev/null -w "%{http_code}" -X DELETE $PROXY/repos/{owner}/{repo}/issues/42/labels
```

Label names with spaces or special characters must be URL-encoded (e.g. `bug%20fixing`).

To see which label names exist in the repository:

```bash
curl -s $PROXY/repos/{owner}/{repo}/labels | jq '.[].name'
```

## Assignees

```bash
# Check whether a user can be assigned
curl -s "$PROXY/repos/{owner}/{repo}/issues/42/assignees?assignee=octocat" | jq '.'

# Add assignees
curl -s -X POST $PROXY/repos/{owner}/{repo}/issues/42/assignees \
  -H "Content-Type: application/json" \
  -d '{"assignees":["octocat"]}' | jq '.assignees[].login'

# Remove assignees
curl -s -X DELETE $PROXY/repos/{owner}/{repo}/issues/42/assignees \
  -H "Content-Type: application/json" \
  -d '{"assignees":["octocat"]}' | jq '.assignees[].login'
```

## Response Handling

All responses are JSON (except DELETE which returns `204`). Parse with `jq`:

```bash
# Pretty-print
curl -s $PROXY/repos/{owner}/{repo}/issues/42 | jq '.'

# Extract a field
curl -s $PROXY/repos/{owner}/{repo}/issues/42 | jq '.state'

# Check for errors (GitHub returns non-2xx with JSON error body)
curl -s -w "\nHTTP_CODE: %{http_code}" $PROXY/repos/{owner}/{repo}/issues/999999
```

Common error responses:
- `404` — issue not found or endpoint blocked
- `403` — endpoint not allowed (non-PR/issue path)
- `422` — validation error (e.g. unknown label name; check response body for details)

## Automatic Issue Posting

- **Do not auto-create issues or comments.** Only create, comment on, close, label, or assign issues when the user explicitly requests it.
- If the user asks you to "file an issue" or "close issue #42", do it immediately — do not ask for confirmation.
