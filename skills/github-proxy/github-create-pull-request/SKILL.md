---
name: github-create-pull-request
description: Call the GitHub PR proxy server via REST API to create, update, delete, merge, or list pull requests through the local proxy on port 8086.
---

This skill provides instructions for calling the GitHub PR proxy server directly via REST API. The proxy runs on `localhost:8086` and injects your PAT automatically — no authentication header needed.

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

Before making PR calls, confirm the proxy is up and your credentials are configured:

```bash
curl -s $PROXY/user || echo "Proxy not running or not configured"
```

## How to Call the Proxy

The proxy speaks standard GitHub REST API over HTTP. Use `curl` directly:

```bash
curl -s http://localhost:8086/repos/{owner}/{repo}/pulls
```

For POST/PATCH/PUT with a body:

```bash
curl -s -X POST http://localhost:8086/repos/{owner}/{repo}/pulls \
  -H "Content-Type: application/json" \
  -d '{"title":"My PR","head":"feature","base":"main"}'
```

**Tip:** Save the base URL to avoid repetition:

```bash
PROXY="http://localhost:8086"
```

## Get Your GitHub Username

Required to resolve `{owner}` in all PR endpoints:

```bash
curl -s $PROXY/user | jq '.login'
```

## List Pull Requests

```bash
curl -s "$PROXY/repos/{owner}/{repo}/pulls?state=open&sort=created&direction=desc" | jq '.'
```

Query params: `state` (`open`, `closed`, `all`), `sort` (`created`, `updated`, `popularity`, `long-running`), `direction` (`asc`, `desc`), `per_page`, `page`.

## Create a Pull Request

Required params: `head` (branch), `base` (target branch)

Optional params: `title`, `body`, `draft`, `maintainer_can_modify`

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/pulls \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Add new feature",
    "body": "This adds the feature",
    "head": "feature/my-feature",
    "base": "main"
  }' | jq '.number'
```

The response includes `number` — use it for all subsequent PR operations.

### Writing a Good PR Description

When creating a PR, write a description that helps your team review it efficiently. Focus on **what changed**, **why**, and **how to test it**.

A good PR description includes:
- **Summary** — one-line overview of the change
- **What changed** — bullet points of key modifications
- **Why** — the motivation or problem being solved
- **How to test** — concrete steps to verify the change
- **Notes** — any caveats, follow-ups, or migration steps

## Get a Pull Request

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42 | jq '.'
```

The PR object includes a `comments` field — this counts **discussion comments** (not review comments). To retrieve them, use the issues endpoint below.

## List PR Discussion Comments

GitHub stores PR discussion comments under the **issues** API, not the **pulls** API:

```bash
curl -s $PROXY/repos/{owner}/{repo}/issues/42/comments | jq '.'
```

## Update a Pull Request

```bash
curl -s -X PATCH $PROXY/repos/{owner}/{repo}/pulls/42 \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated title","body":"Updated description","state":"closed"}' | jq '.'
```

Fields: `title`, `body`, `state` (`open`/`closed`), `base` (target branch).

## Delete a Pull Request

```bash
curl -s -X DELETE $PROXY/repos/{owner}/{repo}/pulls/42
```

Returns `204 No Content` on success.

## List Pull Request Files

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/files | jq '.[].filename'
```

## List Pull Request Commits

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/commits | jq '.[].sha'
```

## Update PR Branch (merge latest from base)

```bash
curl -s -X PUT $PROXY/repos/{owner}/{repo}/pulls/42/update-branch \
  -H "Content-Type: application/json" \
  -d '{"expected_head_sha":"abc123"}' | jq '.'
```

`expected_head_sha` is optional — omit it to use the current HEAD. Provide it for optimistic concurrency control to prevent race conditions when the branch is updated concurrently.

## Merge a Pull Request

**Repo convention:** Use **merge commit** (`"merge_method": "merge"`) unless the user specifies otherwise. Ask before using squash or rebase.

```bash
curl -s -X PUT $PROXY/repos/{owner}/{repo}/pulls/42/merge \
  -H "Content-Type: application/json" \
  -d '{
    "commit_title": "Merge pull request #42",
    "merge_method": "merge"
  }' | jq '.'
```

`merge_method`: `merge`, `squash`, or `rebase`. Optional: `commit_title`, `commit_message`, `sha` (required SHA to allow merge).

## Check if PR is Merged

Use a `HEAD` request to avoid fetching the response body:

```bash
curl -s -o /dev/null -w "%{http_code}" -X HEAD $PROXY/repos/{owner}/{repo}/pulls/42/merge
```

Returns `200` if merged, `404` if not.

## Response Handling

All responses are JSON (except DELETE which returns `204`). Parse with `jq`:

```bash
# Pretty-print
curl -s $PROXY/repos/{owner}/{repo}/pulls/42 | jq '.'

# Extract a field
curl -s $PROXY/repos/{owner}/{repo}/pulls/42 | jq '.state'

# Check for errors (GitHub returns non-2xx with JSON error body)
curl -s -w "\nHTTP_CODE: %{http_code}" $PROXY/repos/{owner}/{repo}/pulls/999999
```

Common error responses:
- `404` — PR not found or endpoint blocked
- `403` — endpoint not allowed (non-PR path)
- `422` — validation error (check response body for details)

## Automatic PR Posting

- **Do not auto-create pull requests.** Only create a PR when the user explicitly requests it.
- After creating a branch and committing changes, present the PR details to the user and ask before submitting.
- If the user asks you to "submit a PR", create it immediately — do not ask for confirmation.
