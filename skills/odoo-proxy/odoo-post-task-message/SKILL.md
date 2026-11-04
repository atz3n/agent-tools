---
name: odoo-post-task-message
description: Call the Odoo proxy server via REST API to post a note message to a ticket thread through the local proxy on port 8087.
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
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello world"}' | jq '.'
```

**Tip:** Save the base URL to avoid repetition:

```bash
PROXY="http://localhost:8087"
```

## Post a Message

Posts a note message to a ticket thread via `project.task.message_post`. Requires `id` parameter (integer thread ID, typically the task ID) and a `body` field in the JSON body.

```bash
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello world"}' | jq '.'
```

### Response

Returns a JSON object with a `message` key containing the posted message data:

```bash
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello world"}' | jq '.message'
```

Key fields in the response:

| Field | Description |
|-------|-------------|
| `id` | Message ID (newly created) |
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

### Error Responses

- `400` — Missing or invalid `id` parameter, missing `body` field, or invalid JSON
- `404` — Endpoint not found (non-whitelisted path)
- `502` — Odoo backend unreachable or session error

```bash
# Missing body (should return 400)
curl -s -w "\nHTTP_CODE: %{http_code}" \
  -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{}'

# Missing id (should return 400)
curl -s -w "\nHTTP_CODE: %{http_code}" \
  -X POST "$PROXY/task/message" \
  -H "Content-Type: application/json" \
  -d '{"body": "test"}'
```

## Post Different Message Types

### Public note (visible only to internal users)

```bash
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "Internal note", "message_type": "comment", "subtype_xmlid": "mail.mt_note"}' | jq '.'
```

### Public message (visible to portal users)

```bash
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "Public update", "subtype_xmlid": ""}' | jq '.'
```

### Email notification

```bash
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "Email sent to partners", "message_type": "email"}' | jq '.'
```

## Common Patterns

```bash
# Post a message and check the message ID
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "Test message"}' | jq '.message.id'

# Post a message with HTML content
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "<p>HTML <b>content</b> here</p>"}' | jq '.'

# Post a message and verify it appears in thread messages
curl -s -X POST "$PROXY/task/message?id=123" \
  -H "Content-Type: application/json" \
  -d '{"body": "New message"}' && \
  curl -s "$PROXY/task/messages?id=123" | jq '.messages | length'
```
