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
  `{"error": "..."}` body. Gated by `THUNDERBIRD_PROXY_TOKEN`.
- **Add-on face** — exactly `POST /addon/hello`, `GET /addon/poll`,
  `POST /addon/result`, `GET /addon/status`. Gated by its own
  `THUNDERBIRD_ADDON_TOKEN`, and every response is signed with
  `THUNDERBIRD_ADDON_SECRET` (`X-Proxy-Proof`) so the add-on can verify it
  is talking to *your* proxy. The wire can only ever trigger whitelisted
  commands with schema-checked params; it cannot drive arbitrary code in
  Thunderbird.

## Requirements

- Thunderbird **153 or newer** on the machine running the proxy (the
  `messages.sendMessage` / `messages.saveMessage` APIs used here were added
  in 153; older releases need the superseded `mailTasks` API family).
- The proxy in Docker (like the other servers) — the add-on connects to the
  published loopback port `127.0.0.1:8090`.

## Setup

```bash
cd servers/thunderbird-proxy

# 1. Three secrets are mandatory — the proxy refuses to start without them:
#    the agent token, the add-on's own token, and the response-signing secret.
openssl rand -hex 32 > secrets/thunderbird-proxy-token.txt
openssl rand -hex 32 > secrets/thunderbird-addon-token.txt
openssl rand -hex 32 > secrets/thunderbird-addon-secret.txt

# 2. Optional recipient allowlist for send/draft (one address per line).
# echo "friend@example.com" > secrets/allowed-recipients.txt

# 3. Build and run
./scripts/build-docker.sh
./scripts/run-docker.sh          # proxy at http://localhost:8090
./scripts/stop-docker.sh         # done
```

To let a [pia](../../harnesses/pia/README.md) agent use the mail skill, forward the token into its container at start:

```bash
export THUNDERBIRD_PROXY_TOKEN=$(cat secrets/thunderbird-proxy-token.txt) && pia run -e THUNDERBIRD_PROXY_TOKEN
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
   `http://127.0.0.1:8090` — prefer the literal IP: Thunderbird may resolve
   `localhost` to `::1`, which the loopback-published proxy does not listen
   on, and the fetch then fails with `NetworkError`), the **add-on token**
   from `secrets/thunderbird-addon-token.txt` and the **response secret**
   from `secrets/thunderbird-addon-secret.txt`. The toolbar badge shows `on`
   when the bridge is connected.

### Troubleshooting

- **`NetworkError` / `Cross-Origin Request Blocked` on *Test connection***
  — Thunderbird may resolve `localhost` to `::1` (the proxy listens on IPv4
  loopback only) and may apply CORS to the add-on's fetches even with the
  host permission declared. Use the literal `http://127.0.0.1:8090`. The
  proxy answers CORS preflights (`OPTIONS` with a `moz-extension://`
  origin) on every path with `204` and echoes that origin on responses, so
  the bridge works regardless of the permission-grant behaviour; preflight
  handling is logged as `OPTIONS <path> 204 ... preflight`. Other origins
  get no CORS at all, and the token gates every real request either way.
- **"proxy response signature invalid" in the add-on console** — the
  service answering the port did not sign its responses with your
  `THUNDERBIRD_ADDON_SECRET`. Either the secret differs between options
  page and `secrets/thunderbird-addon-secret.txt`, the proxy was restarted
  with a different secret, or something else is listening on the port — the
  add-on refuses to execute anything from it by design.

## Endpoints

All requests need `Authorization: Bearer <token>`. Message ids are numeric
Thunderbird keys that are only valid for the current Thunderbird session —
re-fetch them after a Thunderbird restart.

| Method | Path | Command | Notes |
|--------|------|---------|-------|
| GET | `/status` | — | proxy-local: `connected`, `lastSeen`, `queued`, add-on info |
| GET | `/accounts` | `accounts.list` | `?includeSubFolders=` |
| GET | `/identities` | `identities.list` | `?account=<accountId>` (optional) — the ids for `identityId` when sending |
| GET | `/folders` | `folders.list` | `?account=<accountId>` (required) |
| GET | `/mail/list` | `messages.list` | `?folderId=` or `?account=&folder=`; `?limit=` (≤200), `?offset=`; newest first |
| GET | `/mail/search` | `messages.search` | at least one of `?subject=`, `?body=`, `?author=`, `?to=`, `?unread=`, `?account=`/folder scope; up to 500 results |
| GET | `/mail/{id}` | `message.get` | header + body parts |
| POST | `/mail/send` | `message.send` | `{"to":[...],"subject":...,"body":...,"cc"?,"bcc"?,"html"?,"identityId"?}` |
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
| `THUNDERBIRD_PROXY_TOKEN` | — **required** | agent-face secret; startup exits without it |
| `THUNDERBIRD_ADDON_TOKEN` | — **required** | add-on-face secret (separate so a leak on one face cannot use the other) |
| `THUNDERBIRD_ADDON_SECRET` | — **required** | HMAC key for signing add-on-face responses (`X-Proxy-Proof`) |
| `COMMAND_TIMEOUT` | `30` | seconds an agent request waits for the add-on |
| `ALLOWED_SENDERS` | *(any)* | comma-separated recipient allowlist for send/draft |

The three secrets live in `secrets/*.txt` (gitignored) and are loaded by
`run-docker.sh`.

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

- Each face is gated by its own token, compared in constant time, never
  logged. Unlike the llm-proxy there is no open default — this proxy can
  read and send mail as you.
- **Mutual trust.** The add-on authenticates to the proxy with
  `THUNDERBIRD_ADDON_TOKEN`; the proxy authenticates *to the add-on* by
  HMAC-signing every add-on-face response over a per-request nonce with
  `THUNDERBIRD_ADDON_SECRET`. The add-on refuses to execute any command it
  cannot verify, so a process that squats the port while the proxy is down
  (or a wrong URL in the options) cannot feed it commands — and it captures
  only the add-on token, which is worthless on the agent face.
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
- On builds where `messages.sendMessage` cannot be unlocked (the documented
  `messages.send` permission is rejected by the manifest validator), sending
  falls back to `compose.beginNew` + `compose.sendMessage` — a compose window
  briefly opens and closes itself after the send.
- Thunderbird < 153 is not supported by the current API handlers.
