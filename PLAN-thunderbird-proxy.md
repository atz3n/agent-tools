# Plan — thunderbird-proxy (port 8090) + Thunderbird add-on

Goal: manage emails (read, search, send, organize) through a local proxy exactly like the
other proxies — `curl localhost:8090/...`, credentials never in the agent's hands, endpoint
whitelist, Docker via compose, an agent skill under `skills/thunderbird-proxy/`.

Docs: https://developer.thunderbird.net/add-ons/about-add-ons.md
MailExtension API reference: https://webextension-api.thunderbird.net/

---

## 1. Core architectural constraint (drives everything)

A Thunderbird add-on is a WebExtension: it **cannot bind a port** and Thunderbird offers no
inbound HTTP. Native messaging only works for binaries *Thunderbird launches*, not for a
standalone server. So the connection must be initiated **by the add-on, outbound**:

```
Agent → curl → localhost:8090 (thunderbird-proxy)  ── enqueue command ──┐
                                                                       │
  Thunderbird add-on (background script)                               │
    long-poll GET /addon/poll   ◄── one pending command ───────────────┘
    execute via browser.mail.* APIs (mailTasks / mailActions / messages / accounts)
    POST /addon/result  { id, ok | error, data }
Agent's original HTTP request blocks until the result arrives (or times out).
```

This is a **command-queue bridge**, not a reverse proxy. The proxy exposes two faces:

- **Agent face** — clean REST endpoints (`/mail/...`, `/accounts`, ...) that the agent/skill calls.
  Each request is translated into a command, correlated by id, and answered when the add-on
  reports back.
- **Add-on face** — exactly three endpoints: `/addon/hello`, `/addon/poll`, `/addon/result`.

Consequences to design around:
- If Thunderbird isn't running, commands queue briefly then **504** ("thunderbird not connected")
  — clear error message, matching the proxies' uniform `{"error": ...}` body.
- Single add-on instance assumed (single-user, KISS); a second `hello` replaces the first.

## 2. Target APIs inside Thunderbird (verify against webextension-api docs)

- `browser.mailAccounts` — list accounts, folders, identities
- `browser.mailTasks` — list/read messages, message parts, search
- `browser.mailActions` — mark read/unread/star, move, copy, delete, archive
- `browser.compose` + `browser.messages.send` — draft & send
- `browser.addressBooks` — contacts (phase 2, optional)
- Manifest permissions: `accountsRead`, `messagesRead`, `messagesModify`, `addressBooks`,
  plus `host_permissions`/`permissions` entry for `http://localhost:8090/*` and `storage`.
- **Decision to make early (spike in Phase 0):** MV2 vs MV3 (TB 128+ supports MV3; see
  `add-ons/whats-new/manifest-v3.md`). Long-lived pending `fetch()` for long-polling must
  survive the MV3 background context — if not, fall back to `alarms`-driven short polling
  (e.g. every 2 s) with the same protocol.

## 3. Repository layout (mirrors the other servers)

```
servers/thunderbird-proxy/
├── thunderbird_proxy/       # package
│   ├── __init__.py
│   ├── config.py            # env vars + logging (same style as llm_proxy/config.py)
│   ├── whitelist.py         # agent-face endpoint patterns + command-name table
│   ├── bridge.py            # command queue, add-on session, request↔result correlation
│   └── server.py            # ThreadingHTTPServer, both faces, SIGTERM/SIGINT handler
├── addon/                   # the Thunderbird add-on (WebExtension)
│   ├── manifest.json
│   ├── background.js        # poll loop, command dispatch to browser.mail.* APIs
│   ├── commands.js          # one handler per command name (maps to mail.* calls)
│   ├── options/options.html + options.js   # proxy URL + token config (browser.storage)
│   └── images/              # icons
├── docker/                  # Dockerfile (python:3.14-alpine) + docker-compose.yml (127.0.0.1:8090)
├── scripts/                 # build/run/pause/stop/lint/test/coverage/clean (copy llm-proxy's)
├── secrets/                 # thunderbird-proxy-token.txt (gitignored)
├── spec/                    # openapi.yml describing the agent face
├── tests/                   # unittest suite
├── pyproject.toml           # ruff + pyright, same as the others
└── README.md
```

Plus:
- `skills/thunderbird-proxy/thunderbird-mail/SKILL.md` — curl usage, Docker-network detection
  (`localhost` vs `host.docker.internal`), same style as the odoo/github skills. Note there the
  proxy is only useful while Thunderbird runs on the host with the add-on enabled.
- `.gitignore` entry for the new `secrets/` file; `AGENTS.md` + `README.md` table updates.

## 4. Bridge protocol (proxy ⇄ add-on)

All bodies JSON; both faces require `Authorization: Bearer <THUNDERBIRD_PROXY_TOKEN>`.

| Endpoint | Method | Purpose |
|---|---|---|
| `/addon/hello` | POST | Add-on registers: reports TB version + configured accounts. Proxy flips state to "connected". |
| `/addon/poll` | GET | Long-poll (up to ~30 s) for one pending command; returns `{id, command, params}` or `204`/empty on timeout. |
| `/addon/result` | POST | `{id, ok, data?, error?}` — resolves the waiting agent request. |

Command names are the *internal* whitelist: a request path maps to a fixed command, so the
add-on only ever executes a closed set (unknown command → 404 at the proxy, never forwarded).

## 5. Agent-face endpoints (v1 scope)

| Method | Path | Command | MailExtension call |
|---|---|---|---|
| GET | `/status` | — (proxy-local) | proxy-only: add-on connected? last seen? pending commands? |
| GET | `/accounts` | `accounts.list` | mailAccounts.list |
| GET | `/folders?account=` | `folders.list` | mailAccounts.listFolders |
| GET | `/mail/list?account=&folder=&limit=&offset=` | `messages.list` | mailTasks.list |
| GET | `/mail/{id}` | `message.get` | mailTasks.get (headers + text/plain body, `raw` flag later) |
| GET | `/mail/search?query=&account=&folder=` | `messages.search` | mailTasks.query |
| POST | `/mail/send` `{to[],cc?,subject,body,html?}` | `message.send` | compose.begin → compose.end(modifyToSend) / messages.send |
| POST | `/mail/draft` | `message.draft` | compose.begin → compose.end(modifyToDraft) |
| PATCH | `/mail/{id}` `{read?,starred?,folder?}` | `message.update` | mailTasks.update |
| DELETE | `/mail/{id}` | `message.delete` | mailActions.delete |

Everything else → 404 (uniform error body), whitelisted path + wrong method → 405.
`HEAD` supported on GET paths. Ids are opaque strings (mailMessageId) — pass through unchanged.

Phase 2 (later, not in v1): address book endpoints, attachments (`/mail/{id}/attachments`),
`raw`/EML retrieval, mailbox sync triggers, notifications on new mail (`/events` SSE).

## 6. Configuration (env vars, same pattern)

| Var | Default | Meaning |
|---|---|---|
| `PROXY_PORT` | `8090` | listen port |
| `BIND_HOST` | `0.0.0.0` in Docker; set `127.0.0.1` on host | |
| `THUNDERBIRD_PROXY_TOKEN` | — (required) | shared secret, agent face **and** add-on face |
| `COMMAND_TIMEOUT` | `30` (s) | how long an agent request waits for the add-on |
| `TB_UPSTREAM_TIMEOUT` | n/a | not needed — no HTTP upstream; `COMMAND_TIMEOUT` is the timeout knob |

Secret: `secrets/thunderbird-proxy-token.txt`, loaded by `run-docker.sh` → env var.
The token is **mandatory at startup** here (unlike llm-proxy's optional gate): this proxy can
read and send mail, so an open default is not acceptable — a shared secret is the only thing
standing between any localhost process and "send email as you". The same token is entered once
in the add-on's options page (persisted via `browser.storage.local`).

## 7. Docker & networking details

- `python:3.14-alpine`, `docker compose -p thunderbird-proxy`, publish `127.0.0.1:8090:8090`.
- The **add-on runs on the host** (Thunderbird is a desktop app) and connects to
  `http://localhost:8090` — the published loopback port. No `host.docker.internal` needed in
  that direction; only the *agent-in-container* case needs `host.docker.internal:8090`
  (handled by the skill's network detection, like the other skills).
- Plain HTTP is acceptable because it is loopback-only; document that LAN use requires TLS or
  an SSH tunnel, and refuse to publish on non-loopback in the compose file.

## 8. Implementation phases

- [ ] **Phase 0 — Spike (½ day):** hand-write a minimal TB add-on (manifest + background.js)
      that polls `http://localhost:8090/addon/poll` against a throwaway Python stub; confirm
      long-pending `fetch()` works in the current TB release and pick MV2 vs MV3 accordingly.
      Confirm which `mailTasks`/`mailActions` build the user's TB version needs (set
      `strict_min_version`).
- [ ] **Phase 1 — Proxy skeleton:** `config.py`, `whitelist.py`, `bridge.py` (queue +
      `threading.Event` correlation + connection state + timeouts), `server.py` with the three
      `/addon/*` endpoints and a stubbed agent face. Tests for queue correlation, token gate,
      504-when-disconnected, whitelist.
- [ ] **Phase 2 — Agent face:** map every REST endpoint to commands; `spec/openapi.yml`;
      504/503 semantics (add-on disconnected vs command timeout); logging format
      `[proxy] <ISO-8601> <METHOD> <PATH> <STATUS> from <IP>`.
- [ ] **Phase 3 — Add-on:** manifest (permissions listed in §2), poll loop with exponential
      backoff while the proxy is down, `hello` on startup, command handlers in `commands.js`,
      options page for URL + token, `web-ext lint`.
- [ ] **Phase 4 — Docker + scripts:** Dockerfile, compose, the seven scripts (copied/adapted
      from llm-proxy), secrets handling.
- [ ] **Phase 5 — Skill + docs:** `skills/thunderbird-proxy/thunderbird-mail/SKILL.md`,
      server `README.md`, updates to root `README.md` and `AGENTS.md` (component table,
      directory tree, env-var list, testing section).
- [ ] **Phase 6 — End-to-end acceptance:** real Thunderbird with a test account —
      list accounts, list inbox, read a message, send a message to self, mark read, delete;
      kill Thunderbird mid-command → proxy returns 504, recovers when it restarts
      (add-on re-registers automatically).

## 9. Testing plan

- `tests/test_server.py` (unittest, no real Thunderbird): whitelist (allowed/blocked paths,
  405 on wrong method), token gate (401, constant-time compare), bridge unit tests — enqueue →
  fake add-on polls → posts result → original handler returns it; command timeout → 504;
  add-on disconnect → pending commands fail fast; config loading + mandatory-token startup
  validation; logging format. `./scripts/test-project.sh`, `./scripts/lint-project.sh` (ruff).
- Add-on: `web-ext lint`; manual run via `about:debugging` → "Load Temporary Add-on"
  (documented in README — temporary load resets on restart, so final install is `web-ext build`
  → install the `.xpi` from file).
- End-to-end checklist = Phase 6 above.

## 10. Security notes (for README/AGENTS.md)

- Token mandatory; both faces gated; token never logged.
- Proxy never stores message bodies — commands/results stream through and only the pending
  queue is in memory; nothing persisted to disk (no secrets dir for mail data).
- Closed command set: the add-on executes only whitelisted command names with schema-checked
  params; the agent can never inject arbitrary JS into Thunderbird.
- Add-on side: minimal permissions, no `browserAction` UI beyond a status badge (connected /
  disconnected) — nice-to-have, phase 3.

## 11. Open questions (answer before Phase 1)

1. **Which Thunderbird version** is installed? Determines MV2/MV3 and whether
   `mailTasks`/`mailActions` exist (TB ≥ 132) or `mailExtended` (deprecated) is needed.
2. **Is the proxy meant to run inside Docker on the same machine as Thunderbird?** (Assumed
   yes — matches the other proxies; the plan depends on it.)
3. v1 send format: **plain text only, or HTML too?** (Plan allows both; HTML costs a little
   more add-on work.)
4. Should outgoing send be **policy-gated** in the proxy (e.g. an optional
   `ALLOWED_RECIPIENTS` / always-draft-instead-of-send flag), analogous to llm-proxy's
   `ALLOWED_MODELS`? Recommended as an optional env var, default off.
