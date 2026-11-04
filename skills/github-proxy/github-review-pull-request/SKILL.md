---
name: github-review-pull-request
description: Call the GitHub PR proxy server via REST API to list, create, submit, update, dismiss, or delete pull request reviews and review comments through the local proxy on port 8086.
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

## Review Methodology

When reviewing a PR, **never rely on the `patch` field from the `/pulls/{number}/files` endpoint** to verify file contents. GitHub silently truncates it for large files, which can cause false reports of missing or incomplete content. Instead:

1. List changed files via `GET /pulls/{number}/files` to get filenames and status.
2. **Read the full file directly** from the repo (via `read_file` or `git show`) to verify correctness and completeness.
3. Use the API diff only as a quick overview of what changed, not as a source of truth.

## Verification Before Posting

Before flagging any issue in a review, **verify your claim against the actual code on disk**:

1. **Re-read the exact line** you are about to flag — do not rely on memory or the API patch.
2. **Run the relevant test** in the project's test suite to confirm the behavior matches your claim.
3. If a test already covers the behavior you are about to flag, **read the test first** — the code may already be correct and your "issue" is a false positive.

Posting a false-positive issue wastes the user's time and erodes trust. One false positive is worse than one missed issue. If you are unsure, present it as a question ("I noticed X, but the test expects Y — is this intentional?") rather than a definitive bug.

## Verify Proxy is Running

Before making review calls, confirm the proxy is up and your credentials are configured:

```bash
curl -s $PROXY/user || echo "Proxy not running or not configured"
```

## How to Call the Proxy

The proxy speaks standard GitHub REST API over HTTP. Use `curl` directly:

```bash
curl -s http://localhost:8086/repos/{owner}/{repo}/pulls/{number}/reviews
```

For POST/PATCH/PUT with a body:

```bash
curl -s -X POST http://localhost:8086/repos/{owner}/{repo}/pulls/42/reviews \
  -H "Content-Type: application/json" \
  -d '{"body":"Looks good","event":"APPROVE"}'
```

**Tip:** Save the base URL to avoid repetition:

```bash
PROXY="http://localhost:8086"
```

## Get Your GitHub Username

Required to resolve `{owner}` in all review endpoints:

```bash
curl -s $PROXY/user | jq '.login'
```

## List Reviews

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/reviews | jq '.'
```

## Create a Review

Creates a **pending** review by default (not submitted). Leave `event` blank to keep it pending.

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/pulls/42/reviews \
  -H "Content-Type: application/json" \
  -d '{
    "body": "Looks good, just fix the typo",
    "event": "COMMENT"
  }' | jq '.id'
```

`event` values: `APPROVE`, `REQUEST_CHANGES`, `COMMENT`, or omit for `PENDING`.

To include inline comments on specific lines, add a `comments` array:

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/pulls/42/reviews \
  -H "Content-Type: application/json" \
  -d '{
    "body": "Please fix these issues",
    "event": "REQUEST_CHANGES",
    "comments": [
      {"path": "src/main.py", "line": 10, "body": "Add type hints"}
    ]
  }' | jq '.'
```

## Submit a Pending Review

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/pulls/42/reviews/123/events \
  -H "Content-Type: application/json" \
  -d '{"event": "APPROVE"}' | jq '.'
```

Replace `123` with the review ID from the create response.

## Update a Review

```bash
curl -s -X PUT $PROXY/repos/{owner}/{repo}/pulls/42/reviews/123 \
  -H "Content-Type: application/json" \
  -d '{"body": "Updated review comment"}' | jq '.'
```

Only the `body` can be updated.

## Delete a Pending Review

```bash
curl -s -X DELETE $PROXY/repos/{owner}/{repo}/pulls/42/reviews/123
```

Only works for reviews still in `PENDING` state.

## Dismiss a Review

```bash
curl -s -X PUT $PROXY/repos/{owner}/{repo}/pulls/42/reviews/123/dismissals \
  -H "Content-Type: application/json" \
  -d '{"message": "Superseded by new review", "event": "DISMISS"}' | jq '.'
```

## List Comments for a Review

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/reviews/123/comments | jq '.'
```

## List Review Comments

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/comments | jq '.'
```

## List PR Discussion Comments

GitHub stores PR discussion comments under the **issues** API, not the **pulls** API. To list discussion comments on a PR:

```bash
curl -s $PROXY/repos/{owner}/{repo}/issues/42/comments | jq '.'
```

Note: The PR object's `comments` field counts discussion comments, not review comments. Use this endpoint to retrieve them.

## Create a Review Comment

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/pulls/42/comments \
  -H "Content-Type: application/json" \
  -d '{
    "body": "Consider adding error handling here",
    "commit_sha": "abc123",
    "path": "src/main.py",
    "line": 10
  }' | jq '.'
```

Required: `body`, `commit_sha`, `path`, `line`. Optional: `side` (`LEFT`/`RIGHT`), `start_line`, `start_side`.

## Update a Review Comment

```bash
curl -s -X PATCH $PROXY/repos/{owner}/{repo}/pulls/42/comments/999 \
  -H "Content-Type: application/json" \
  -d '{"body": "Updated comment text"}' | jq '.'
```

## List Review Comment Reactions

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/comments/999/reactions | jq '.'
```

## Create a Review Comment Reaction

```bash
curl -s -X POST $PROXY/repos/{owner}/{repo}/pulls/42/comments/999/reactions \
  -H "Content-Type: application/json" \
  -d '{"content": "+1"}' | jq '.'
```

`content` values: `+1`, `-1`, `laugh`, `hooray`, `confused`, `heart`, `heartbreak`, `rocket`, `eyes`.

## Delete a Review Comment Reaction

```bash
curl -s -X DELETE $PROXY/repos/{owner}/{repo}/pulls/42/comments/999/reactions/456
```

Replace `456` with the reaction ID.

## Get a Review Comment

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/comments/999 | jq '.'
```

## Get Replies to a Review Comment

```bash
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/comments/999/replies | jq '.'
```

## Response Handling

All responses are JSON (except DELETE which returns `204`). Parse with `jq`:

```bash
# Pretty-print
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/reviews | jq '.'

# Extract a field
curl -s $PROXY/repos/{owner}/{repo}/pulls/42/reviews | jq '.[0].state'

# Check for errors (GitHub returns non-2xx with JSON error body)
curl -s -w "\nHTTP_CODE: %{http_code}" $PROXY/repos/{owner}/{repo}/pulls/999999/reviews
```

Common error responses:
- `404` — PR not found or endpoint blocked
- `403` — endpoint not allowed (non-PR path)
- `422` — validation error (check response body for details)

## Automatic Review Posting

- **Do not auto-submit reviews.** Create reviews as `PENDING` by default (omit `event`).
- Only submit a pending review (via the `/reviews/{id}/events` endpoint) when the user explicitly requests it.
- If the user asks you to "approve", "request changes", or "submit" a review you just created, submit it immediately — do not ask for confirmation.
