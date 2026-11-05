# agent-tools

Run [Pi Coding Agent](https://pi.dev) instances safely in Docker — and give those agents something safe to talk to.

The centerpiece is **`pia`**, a CLI that runs multiple isolated pi agents in parallel, each in its own container with its own workspace and session, with full visibility into where their network requests actually go. Around it sits a set of tiny proxy servers that expose narrow, whitelisted APIs with credentials injected internally — so an agent can open a PR or read a ticket without ever seeing a token — plus the agent skills and templates that tie it all together.

Everything is deliberately minimal: **Python-stdlib-only** servers (no pip installs), each running as a **single Docker container**, each rejecting every endpoint it doesn't explicitly know.

## Harnesses (`harnesses/`)

Isolated agent runtimes — containers that an agent works inside of, with you in control of what it can touch. Currently one: **`pia`**, a harness for the Pi Coding Agent. More may follow.

### `pia` — run pi agents in isolated containers

Like talking to an agent in your terminal — except it can't touch your machine.

- **Isolation** — the agent works on a mounted directory inside its own container; your home directory, dotfiles, and credentials stay out of reach (opt-in mounts only).
- **Many agents at once** — `pia run backend-api -m ~/backend --ssh` and `pia run frontend -m ~/frontend` in parallel, each with its own name, workspace, and pi session you can `pia rs` back into.
- **One-shot agents** — `pia ask "…"` runs a single prompt in an ephemeral container; `pia create` + `pia ask myproj …` reuses a prepared one.
- **Full network visibility** — `pia monitor` and `pia urls` show exactly where an agent's requests go (see below).
- **Convenience flags** — `--ssh` forwards your SSH agent (private keys never mount), `--docker` gives the agent Docker CLI access to the host daemon for building/testing images (strictly opt-in, root-equivalent).

```bash
bash harnesses/pia/scripts/build-docker.sh
bash harnesses/pia/scripts/install-pia.sh    # installs `pia` into ~/.local/bin

pia run myproj -m /path/to/repo --ssh      # interactive agent on a repo
pia ask "Summarize the TODOs in this repo" # one-shot, ephemeral container
pia list                                   # all agent instances
pia stop myproj && pia rs                  # stop, then resume the last session
```

**Watching an agent (`pia monitor`, `pia urls`).** Trust, but verify: a passive `tshark` capture inside each container shows *where the agent's requests actually go* — live with `pia monitor` (destinations plus CPU/memory/net per sample), or retrospectively with `pia urls`, which reports every destination the container has called since it was created, surviving stop/start cycles. HTTPS exposes the hostname (SNI); cleartext HTTP — your traffic to the local proxies on 8086/8087/8088 — shows full URLs. The monitor itself logs nothing.

The rest of the `pia` surface is routine lifecycle management: `create`, `start/run`, `stop`, `remove`, `restart`, `exec`, `sh`, `clean`, plus `keep`/`unkeep`/`rename` to protect a session container from cleanup. Full command reference, monitor internals, and Docker-socket caveats: [harnesses/pia/README.md](harnesses/pia/README.md).

## Proxies (`servers/`) — what agents talk to

Handing an agent a GitHub token or an Odoo login is risky and noisy: the credential ends up in context windows, logs, and shell history, and the agent can call far more than it needs. These proxies flip that around:

- **Least API surface** — every path outside a small regex whitelist is refused (403/404/405). The github-proxy, for example, only speaks PR and review endpoints.
- **Credentials never leave the container** — PATs and logins live in gitignored `secrets/` files, are injected server-side, and agents authenticate by talking to `localhost`.
- **Zero dependencies** — stdlib-only Python, so images are tiny, audits are trivial, and nothing rots.
- **Agent-ready** — each service ships matching `SKILL.md` files so any agent can learn the API by reading one markdown file and calling it with `curl`.

```
Agent (pia container) → curl → localhost:8086 (github-proxy)  → api.github.com
Agent (pia container) → curl → localhost:8087 (odoo-proxy)    → your Odoo instance
Agent (pia container) → curl → localhost:8088 (tasks-server)  → markdown files on a volume
```

| Server | Port | What it does |
|--------|------|--------------|
| [github-proxy](servers/github-proxy/) | 8086 | Reverse proxy for the GitHub REST API, restricted to pull requests, reviews, review comments, and issues. Injects a PAT as a Bearer token. |
| [odoo-proxy](servers/odoo-proxy/) | 8087 | Application server over Odoo: manages the login session internally and exposes `/task/data`, `/task/messages`, and `/task/message` for project tasks. |
| [tasks-server](servers/tasks-server/) | 8088 | REST API + zero-dependency web UI for tasks stored as markdown files with YAML frontmatter, organized per project with auto-incrementing IDs. |

Each server has its own README with endpoints, setup, and configuration.

## Agent Skills (`skills/`)

`SKILL.md` files that teach an agent how to use each tool — plain markdown, `curl`-based, no MCP or JSON-RPC needed. Skills auto-detect whether they run inside Docker and switch between `localhost` and `host.docker.internal` — so the same skill works interactively on the host and inside a `pia` container.

| Feature | Skills |
|---------|--------|
| git | `commit`, `commit-staged` |
| github-proxy | `github-create-pull-request`, `github-review-pull-request`, `github-manage-issues` |
| odoo-proxy | `odoo-get-task-data`, `odoo-get-task-messages`, `odoo-post-task-message` |
| project | `project-new-project`, `project-write-spec`, `project-architecture`, `project-implement`, `project-refine`, `project-qa`, `project-doctor`, `project-help`, `project-autopilot` |
| tasks-server | `tasks-server` |
| misc | `codebase-review`, `loop-prompt` |

Install by copying a skill's directory into your agent's skills folder (e.g. `~/.pi/agent/skills/<feature>/<skill>/`).

## Templates (`templates/`)

- [llm-wiki](templates/llm-wiki/) — a template for LLM-assisted knowledge bases: an idea file you hand to any coding agent, plus the wiki spec and conventions it should maintain.

## Quick Start

**Run an agent** (Docker required):

```bash
bash harnesses/pia/scripts/build-docker.sh
bash harnesses/pia/scripts/install-pia.sh
pia run myproject -m /path/to/repo
```

**Run the proxies** it talks to — each with its own scripts:

```bash
# github-proxy — needs a PAT in secrets/ first:
#   echo "ghp_..." > secrets/github-personal-access-token.txt
cd servers/github-proxy && ./scripts/build-docker.sh && ./scripts/run-docker.sh
curl -s http://localhost:8086/user

# tasks-server — no credentials needed, UI included:
cd servers/tasks-server && ./scripts/build-docker.sh && ./scripts/run-docker.sh
open http://localhost:8088/ui

# stop any service
./scripts/stop-docker.sh
```

odoo-proxy works the same way but needs four credential files in `secrets/` (`odoo-db`, `odoo-url`, `odoo-user`, `odoo-password`) — see its README.

## Development

The `pia` CLI has its own test suite (`harnesses/pia/scripts/run-tests.sh`, filterable by command — see the harness README).

Each server ships scripts for its whole lifecycle — `build-docker.sh`, `run-docker.sh`, `pause-docker.sh`, `stop-docker.sh`, `lint-project.sh` (ruff/pyright), `test-project.sh` (unittest), `coverage-project.sh` (coverage.py with a per-server `fail_under` gate), `clean-project.sh`. Server tests are plain `unittest` and import the server module directly; no server needs to be running:

```bash
cd servers/github-proxy && python3 -m unittest tests.test_server -v
```

## Documentation

[AGENTS.md](AGENTS.md) is the full project reference — architecture, directory layout, per-server technical details, development conventions, and security notes. [harnesses/pia/README.md](harnesses/pia/README.md) covers the harness in depth. Both are written to be read by humans and agents alike.

## Security Notes

- All credentials live in `secrets/` directories, which are gitignored; only `.gitkeep` files are committed.
- Every proxy rejects non-whitelisted endpoints by default.
- Docker Compose binds all proxy ports to `127.0.0.1` — nothing is exposed to the network.
- `pia` containers mount nothing by default; `--ssh` forwards the agent socket (keys never mount), and `--docker` is strictly opt-in because socket access is root-equivalent on the host.

## License

Released under the [MIT License](LICENSE).