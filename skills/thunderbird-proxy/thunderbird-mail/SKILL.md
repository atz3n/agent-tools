---
disable-model-invocation: true
name: thunderbird-mail
description: Manage email through the local thunderbird-proxy on port 8090 — list accounts, create/rename/delete folders, read, search, flag, move, trash, draft, and send messages via your Thunderbird installation.
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

The token is provided by the environment (`THUNDERBIRD_PROXY_TOKEN`) or by the operator; never guess it. This is the **agent-face** token — the Thunderbird add-on uses its own separate add-on token and never shares this one.

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

# Mark as spam — marks junk and moves the message to the account's Junk
# folder (what trains Gmail's spam filter); the response's movedToJunk
# says where it went (false = marked only).
curl -s -H "$AUTH" -X PATCH "$PROXY/mail/<messageId>" \
  -H "Content-Type: application/json" -d '{"junk": true}'

# Batch move — one Thunderbird/IMAP call for the whole list (≤500 ids).
# Always prefer this over PATCH+moveTo per message when sorting many mails.
curl -s -H "$AUTH" -X POST "$PROXY/mail/move" \
  -H "Content-Type: application/json" \
  -d '{"ids":[12,13,14],"to":"<folderId>"}'

# Batch flag — read/star for many messages in one call (one set-level
# Thunderbird call per folder involved, not one per message); no folder
# needed, ids resolve session-wide. If any id is unknown — e.g. Thunderbird
# restarted since you listed — nothing is marked and the error names the id:
# re-list and retry.
curl -s -H "$AUTH" -X POST "$PROXY/mail/mark" \
  -H "Content-Type: application/json" \
  -d '{"ids":[12,13,14],"read":true}'

# Batch trash — moves to the account's Trash in one call; if any listed id
# is already in Trash, nothing is moved and the error names that id (a
# second delete would purge it).
curl -s -H "$AUTH" -X POST "$PROXY/mail/trash" \
  -H "Content-Type: application/json" -d '{"ids":[15,16]}'

# Mark the whole folder read in one call (bulk flag — Thunderbird exposes
# no set-level flag update, so per-message flags stay single PATCHes)
curl -s -H "$AUTH" -X POST "$PROXY/folders/mark-read" \
  -H "Content-Type: application/json" -d '{"folderId":"<folderId>"}'

# Delete one message — moves it to Trash; mail is never permanently deleted.
curl -s -H "$AUTH" -X DELETE "$PROXY/mail/<messageId>"
```

Batch endpoints cover what Thunderbird can do in bulk natively: id arrays
for move/trash, set-level folder operations for bulk read/star, and
whole-folder `mark-read`. Tags are the one flag without a bulk path —
per-message PATCH only; if you must tag many, loop and tell the user it
will be slow. Message ids do not survive a move: the message gets a new id
in the destination folder — re-list before any follow-up operation on
messages you just moved. Gmail IMAP operations are slow (~20-30 s for a
move); expect moves to take seconds, not milliseconds.

## Manage Folders

```bash
# Create a sub-folder — parent by id, or by account + parent name/path
# (case-insensitive name matching, so "INBOX" finds a folder named Inbox)
curl -s -H "$AUTH" -X POST "$PROXY/folders" \
  -H "Content-Type: application/json" \
  -d '{"name":"Newsletter","parentFolderId":"<parentFolderId>"}'
curl -s -H "$AUTH" -X POST "$PROXY/folders" \
  -H "Content-Type: application/json" \
  -d '{"name":"Newsletter","account":"<accountId>","folder":"INBOX"}'

# Rename — folder ids are path-derived and CHANGE on rename: take the new
# id from the response (folder.id). Renaming onto an existing sibling name
# is refused (502 "a folder already exists there").
curl -s -H "$AUTH" -X PATCH "$PROXY/folders/<folderId>" \
  -H "Content-Type: application/json" -d '{"name":"Archive"}'

# Delete — only empty folders; a folder that still holds messages, or whose
# sub-folders do, gets 502 "folder is not empty" (move or trash them first).
curl -s -H "$AUTH" -X DELETE "$PROXY/folders/<folderId>"
```

Percent-encode the whole folder id in the path (ids contain `/`, `:` and
sometimes `[ ]`, e.g. `account4%3A%2F%2FINBOX`); folder names must not
contain `/`.

**Known limitation:** deleting folders on IMAP accounts currently fails
inside Thunderbird itself (upstream bug 2013929) — the proxy reports a clean
`502` and nothing is lost (Gmail may even have moved the folder to Trash
server-side). Deletion works on Local Folders. Do not retry an IMAP folder
delete; report it to the user instead.

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
allowed, `502` Thunderbird reported a failure (e.g. folder not found,
folder not empty, rename collision, IMAP folder delete — upstream bug),
`504` add-on disconnected or command timed out.
