---
name: odoo-get-task-messages
description: Call the Odoo proxy server via REST API to read thread messages through the local proxy on port 8087.
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
curl -s $PROXY/task/messages?id=1 || echo "Proxy not running or not configured"
```

## How to Call the Proxy

The proxy speaks JSON over HTTP. Use `curl` directly:

```bash
curl -s "$PROXY/task/messages?id=62263" | jq '.'
```

**Tip:** Save the base URL to avoid repetition:

```bash
PROXY="http://localhost:8087"
```

## Read Thread Messages

Fetches messages for a thread via `mail.thread.messages`. Requires `id` parameter (integer thread ID, typically the task ID).

```bash
curl -s "$PROXY/task/messages?id=123" | jq '.'
```

### Response

Returns a JSON object with a `messages` key containing an array of message objects:

```bash
curl -s "$PROXY/task/messages?id=123" | jq '.messages'
```

Each message includes:

| Field | Description |
|-------|-------------|
| `id` | Message ID |
| `body` | HTML message body |
| `date` | Message date/time |
| `email_from` | Sender email with display name |
| `message_type` | Type (`comment`, `notification`, `email`) |
| `subtype_id` | Subtype array `[id, "Name"]` |
| `author` | Author object with `id`, `name`, `user` info |
| `record_name` | Associated task title |
| `res_id` | Resolved record ID |
| `create_date` | Creation timestamp |
| `write_date` | Last modified timestamp |
| `attachments` | Array of attachments |
| `reactions` | Array of reactions |
| `recipients` | Array of recipients |
| `trackingValues` | Field change history (for notifications) |

### Message Types

- `comment` — A user comment with a `body`
- `notification` — System event (stage change, deadline update, etc.) with `trackingValues`
- `email` — Incoming/outgoing email

### Error Responses

- `400` — Missing or invalid `id` parameter
- `404` — Endpoint not found (non-whitelisted path)
- `502` — Odoo backend unreachable or session error

```bash
# Check for errors
curl -s -w "\nHTTP_CODE: %{http_code}" "$PROXY/task/messages?id=invalid"
```

## Extract Common Fields

```bash
# Count messages
curl -s "$PROXY/task/messages?id=123" | jq '.messages | length'

# Latest message body
curl -s "$PROXY/task/messages?id=123" | jq '.messages[0].body'

# Latest message author
curl -s "$PROXY/task/messages?id=123" | jq '.messages[0].author.name'

# Latest message date
curl -s "$PROXY/task/messages?id=123" | jq '.messages[0].date'

# Filter comments only (exclude system notifications)
curl -s "$PROXY/task/messages?id=123" | jq '[.messages[] | select(.message_type == "comment")]'

# Messages with attachments
curl -s "$PROXY/task/messages?id=123" | jq '[.messages[] | select(.attachments | length > 0)]'
```

## Iterate Over Messages

```bash
# Print each message's date, author, and first line of body
curl -s "$PROXY/task/messages?id=123" | jq -r '.messages[] | "\(.date) | \(.author.name) | \(.body[:80])"'
```
