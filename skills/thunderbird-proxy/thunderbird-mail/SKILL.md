---
disable-model-invocation: true
name: thunderbird-mail
description: Manage email through the local thunderbird-proxy on port 8090 — list accounts and folders, read, search, flag, move, delete, draft, and send messages via your Thunderbird installation.
---

This skill provides instructions for calling the thunderbird-proxy via REST. The proxy runs on `localhost:8090` and executes every operation inside Thunderbird through its bridge add-on — mail accounts and credentials stay in Thunderbird, you only see JSON.

Unlike the other proxies, this one **requires Thunderbird to be running** on the host with the bridge add-on connected. Every request needs the shared token.

## Network Note

Agents may run inside a Docker container where `localhost` points to the container itself, not the host. Detect your environment and set `PROXY` automatically:

```bash
if [ -f /.dockerenv ] || grep -qE 'docker|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
  PROXY="http://host.docker.internal:8090"
else
  PROXY="http://localhost:8090"
fi
```

## Authenticate

The token is provided by the environment (`THUNDERBIRD_PROXY_TOKEN`) or by the operator; never guess it.

```bash
AUTH="Authorization: Bearer $THUNDERBIRD_PROXY_TOKEN"
```

## Verify the Bridge is Alive

`/status` is answered by the proxy itself; `connected: true` means Thunderbird's add-on is attached:

```bash
curl -s -H "$AUTH" "$PROXY/status"
# {"connected": true, ...}   -> ready
# {"connected": false, ...}  -> start Thunderbird (add-on auto-reconnects)
```

A `504` on any other endpoint means the same thing: the add-on is not there.

## Explore

```bash
curl -s -H "$AUTH" "$PROXY/accounts"                          # accounts (id, name, type)
curl -s -H "$AUTH" "$PROXY/identities"                        # sending identities — ids for identityId
curl -s -H "$AUTH" "$PROXY/folders?account=<accountId>"       # folders of one account
```

## List, Read, Search

```bash
# Newest 10 of a folder (by id, or by account + folder name)
curl -s -H "$AUTH" "$PROXY/mail/list?folderId=<folderId>&limit=10"
curl -s -H "$AUTH" "$PROXY/mail/list?account=<accountId>&folder=Inbox&limit=10"

# One message: header + body parts (text/plain sections are in parts)
curl -s -H "$AUTH" "$PROXY/mail/<messageId>"

# Search (at least one field; optional account/folder scope)
curl -s -H "$AUTH" "$PROXY/mail/search?subject=invoice&folderId=<folderId>"
curl -s -H "$AUTH" "$PROXY/mail/search?unread=true&account=<accountId>"
curl -s -H "$AUTH" "$PROXY/mail/search?to=someone@example.com"
```

Message ids are numeric Thunderbird keys, valid only for the current Thunderbird
session — re-fetch them after a Thunderbird restart.

## Organize

```bash
curl -s -H "$AUTH" -X PATCH "$PROXY/mail/<messageId>" \
  -H "Content-Type: application/json" -d '{"read": true}'
# also: {"starred": true}, {"tags": ["work"]}, {"moveTo": "<folderId>"}

curl -s -H "$AUTH" -X DELETE "$PROXY/mail/<messageId>"
```

## Send and Draft

`/mail/send` sends real email through the Thunderbird identity — confirm recipients with the user before sending unless the task explicitly authorizes sending.

```bash
curl -s -H "$AUTH" -X POST "$PROXY/mail/send" \
  -H "Content-Type: application/json" \
  -d '{"to":["someone@example.com"],"cc":[],"subject":"Subject","body":"Plain text body","identityId":"id1"}'

# Same body shape, saved to Drafts instead of sent:
curl -s -H "$AUTH" -X POST "$PROXY/mail/draft" \
  -H "Content-Type: application/json" \
  -d '{"to":["someone@example.com"],"subject":"Subject","body":"Draft body"}'
```

Add `"identityId"` (from `GET /identities`) to send from a specific address;
without it Thunderbird picks the account's default identity. Add `"html":
"<p>...</p>"` to send HTML mail. If the operator set a recipient allowlist,
unknown recipients return `403` with the address named.

## Errors

All failures return `{"error": "..."}`: `400` invalid body (names the field),
`401` bad token, `403` recipient not allowed, `404`/`405` endpoint not
allowed, `502` Thunderbird reported a failure (e.g. folder not found),
`504` add-on disconnected or command timed out.
