# thunderbird-proxy

Mail for agents, in the same shape as the other proxies in this repo: `curl
localhost:8090`, credentials never in the agent's hands, a regex whitelist on
every route, stdlib-only Python, one Docker container. The twist: mail lives
inside **Thunderbird**, and a Thunderbird add-on (WebExtension) cannot be
called over HTTP — it can only dial out. So the connection is inverted:

```
Agent → curl → localhost:8090 (thunderbird-proxy) ── enqueue command ─┐
                                                                      │
  Thunderbird + add-on (background script)                            │
    long-poll GET /addon/poll   ◄── one command ──────────────────────┘
    execute via browser.accounts / folders / messages APIs
    POST /addon/result  { id, ok, data | error }
Agent's original request blocks until the result arrives (504 on timeout
or when Thunderbird is not connected).
```

The proxy therefore has two faces:

- **Agent face** — the REST API below; every (method, path) maps to one
  command from a closed set. Unknown paths 404, wrong method 405, uniform
  `{"error": "..."}` body.
- **Add-on face** — exactly `POST /addon/hello`, `GET /addon/poll`,
  `POST /addon/result`. The wire can only ever trigger whitelisted commands
  with schema-checked params; it cannot drive arbitrary code in Thunderbird.

## Requirements

- Thunderbird **153 or newer** on the machine running the proxy (the
  `messages.sendMessage` / `messages.saveMessage` APIs used here were added
  in 153; older releases need the superseded `mailTasks` API family).
- The proxy in Docker (like the other servers) — the add-on connects to the
  published loopback port `127.0.0.1:8090`.

## Setup

```bash
cd servers/thunderbird-proxy

# 1. The shared token is mandatory — the proxy refuses to start without it.
openssl rand -hex 32 > secrets/thunderbird-proxy-token.txt

# 2. Optional recipient allowlist for send/draft (one address per line).
# echo "friend@example.com" > secrets/allowed-recipients.txt

# 3. Build and run
./scripts/build-docker.sh
./scripts/run-docker.sh          # proxy at http://localhost:8090
./scripts/stop-docker.sh         # done
```

### Install the add-on

The add-on source is in [`addon/`](addon/).

1. Thunderbird → *Add-ons and Themes* → gear icon → *Debug Add-ons* →
   *Load Temporary Add-on* → pick `addon/manifest.json` (quick testing; the
   add-on unloads on restart).
2. For a permanent install, package it and install from file:

   ```bash
   cd addon && web-ext build        # or: zip -r ../thunderbird-proxy-bridge.xpi *
   ```

   Then *Add-ons and Themes* → gear → *Install Add-on From File*.

3. Open the add-on's *Options*, set the proxy URL (default
   `http://localhost:8090`) and paste the same token from
   `secrets/thunderbird-proxy-token.txt`. The toolbar badge shows `on` when
   the bridge is connected.

## Endpoints

All requests need `Authorization: Bearer <token>`. Message ids are opaque
Thunderbird strings — percent-encode any `/` in them.

| Method | Path | Command | Notes |
|--------|------|---------|-------|
| GET | `/status` | — | proxy-local: `connected`, `lastSeen`, `queued`, add-on info |
| GET | `/accounts` | `accounts.list` | `?includeSubFolders=` |
| GET | `/folders` | `folders.list` | `?account=<accountId>` (required) |
| GET | `/mail/list` | `messages.list` | `?folderId=` or `?account=&folder=`; `?limit=` (≤200), `?offset=` |
| GET | `/mail/search` | `messages.search` | at least one of `?subject=`, `?body=`, `?author=`; optional folder scope |
| GET | `/mail/{id}` | `message.get` | header + body parts |
| POST | `/mail/send` | `message.send` | `{"to":[...],"subject":...,"body":...,"cc"?,"bcc"?,"html"?}` |
| POST | `/mail/draft` | `message.draft` | same body, saved to the identity's Drafts |
| PATCH | `/mail/{id}` | `message.update` | subset of `{"read":bool,"starred":bool,"tags":[...],"moveTo":"folderId"}` |
| DELETE | `/mail/{id}` | `message.delete` | |

`HEAD` is supported on every GET path. Status codes: `400` invalid body
(the error names the field), `401` bad token, `403` recipient outside
`ALLOWED_SENDERS`, `404`/`405` whitelist, `502` the add-on reported a
failure, `504` Thunderbird not connected or command timed out.

```bash
TOKEN=$(cat secrets/thunderbird-proxy-token.txt)
AUTH="Authorization: Bearer $TOKEN"

curl -s -H "$AUTH" localhost:8090/status
curl -s -H "$AUTH" localhost:8090/accounts
curl -s -H "$AUTH" "localhost:8090/mail/list?account=acc1&folder=Inbox&limit=5"
curl -s -H "$AUTH" localhost:8090/mail/<messageId>
curl -s -H "$AUTH" -X POST localhost:8090/mail/send \
  -H "Content-Type: application/json" \
  -d '{"to":["someone@example.com"],"subject":"hi","body":"from the agent"}'
curl -s -H "$AUTH" -X PATCH localhost:8090/mail/<messageId> \
  -H "Content-Type: application/json" -d '{"read":true}'
```

## Configuration (env vars)

| Var | Default | Meaning |
|-----|---------|---------|
| `PROXY_PORT` | `8090` | listen port |
| `BIND_HOST` | `0.0.0.0` (Docker) | set `127.0.0.1` when running on a host |
| `THUNDERBIRD_PROXY_TOKEN` | — **required** | shared secret for both faces; startup exits without it |
| `COMMAND_TIMEOUT` | `30` | seconds an agent request waits for the add-on |
| `ALLOWED_SENDERS` | *(any)* | comma-separated recipient allowlist for send/draft |

The token lives in `secrets/thunderbird-proxy-token.txt` (gitignored) and is
loaded by `run-docker.sh`.

## Tests

```bash
python3 -m unittest discover -s tests -v   # or ./scripts/test-project.sh
./scripts/lint-project.sh
```

The suite covers the endpoint whitelist and command mapping, body validation,
config loading and mandatory-token startup check, the bridge (queue → poll →
result correlation, timeouts, disconnect), and a live-socket HTTP pass
against a fake add-on (token gate, 404/405, 504, end-to-end round-trips).

## Security notes

- The token gates **both** faces and is compared in constant time; it is
  never logged. Unlike the llm-proxy there is no open default — this proxy
  can read and send mail as you.
- The compose file publishes on `127.0.0.1` only. Do not widen that without
  adding TLS or a tunnel.
- Nothing is persisted: commands and results only live in the in-memory
  queue; no message content touches disk.
- The add-on executes only the closed command set with checked parameters.
- Set `ALLOWED_SENDERS` if agents should only mail known addresses.

## Known limitations

- One add-on instance: a second `hello` (e.g. Thunderbird on two machines
  against one proxy) replaces the first.
- If Thunderbird goes down mid-command, the waiting request fails with the
  command timeout; commands queued while disconnected are refused at once.
- Thunderbird < 153 is not supported by the current API handlers.
