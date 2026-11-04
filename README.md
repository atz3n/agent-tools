# agent-tools

Small, self-contained tools that give AI agents safe, focused access to the outside world — a set of local proxy servers that expose a narrow, whitelisted API surface with credentials injected internally, plus the agent skills, a containerized agent harness, and templates that go with them.

Everything is deliberately minimal: the servers are **Python-stdlib-only** (no pip installs), each runs as a **single Docker container**, and each rejects every endpoint it doesn't explicitly know. An agent talking to a proxy can do one job well and nothing else — and never sees a secret.

## Why

Handing an agent a GitHub token or an Odoo login is risky and noisy: the credential ends up in context windows, logs, and shell history, and the agent can call far more than it needs. These proxies flip that around:

- **Least API surface** — every path outside a small regex whitelist is refused (403/404/405). The github-proxy, for example, only speaks PR and review endpoints.
- **Credentials never leave the container** — PATs and logins live in gitignored `secrets/` files, are injected server-side, and agents authenticate by talking to `localhost`.
- **Zero dependencies** — stdlib-only Python, so images are tiny, audits are trivial, and nothing rots.
- **Agent-ready** — each service ships matching `SKILL.md` files so any agent can learn the API by reading one markdown file and calling it with `curl`.

## Architecture

```
Agent → curl → localhost:8086 (github-proxy)  → api.github.com
Agent → curl → localhost:8087 (odoo-proxy)    → your Odoo instance
Agent → curl → localhost:8088 (tasks-server)  → markdown files on a volume
```

## What's Inside

### Servers (`servers/`)

| Server | Port | What it does |
|--------|------|--------------|
| [github-proxy](servers/github-proxy/) | 8086 | Reverse proxy for the GitHub REST API, restricted to pull requests, reviews, review comments, and issues. Injects a PAT as a Bearer token. |
| [odoo-proxy](servers/odoo-proxy/) | 8087 | Application server over Odoo: manages the login session internally and exposes `/task/data`, `/task/messages`, and `/task/message` for project tasks. |
| [tasks-server](servers/tasks-server/) | 8088 | REST API + zero-dependency web UI for tasks stored as markdown files with YAML frontmatter, organized per project with auto-incrementing IDs. |

Each server has its own README with endpoints, setup, and configuration.

### Agent skills (`skills/`)

`SKILL.md` files that teach an agent how to use each tool — plain markdown, `curl`-based, no MCP or JSON-RPC needed. Skills auto-detect whether they run inside Docker and switch between `localhost` and `host.docker.internal`.

| Feature | Skills |
|---------|--------|
| git | `commit`, `commit-staged` |
| github-proxy | `github-create-pull-request`, `github-review-pull-request`, `github-manage-issues` |
| odoo-proxy | `odoo-get-task-data`, `odoo-get-task-messages`, `odoo-post-task-message` |
| project | `project-new-project`, `project-write-spec`, `project-architecture`, `project-implement`, `project-refine`, `project-qa`, `project-doctor`, `project-help`, `project-autopilot` |
| tasks-server | `tasks-server` |
| misc | `codebase-review`, `loop-prompt` |

Install by copying a skill's directory into your agent's skills folder (e.g. `~/.pi/agent/skills/<feature>/<skill>/`).

### Pi harness (`harness/pia/`) — run agents safely in containers

The centerpiece of this repo: a Docker image that runs the [Pi Coding Agent](https://pi.dev) in an isolated container — like talking to an agent in your terminal, except it can't touch your machine — and **`pia`**, a CLI that manages many such agents at once.

Why run your agent through `pia`:

- **Isolation** — the agent works on a mounted directory inside its own container; your home directory, dotfiles, and credentials stay out of reach (opt-in mounts only).
- **Many agents at once** — `pia run backend-api -m ~/backend --ssh` and `pia run frontend -m ~/frontend` in parallel, each with its own name, its own workspace, and its own pi session you can `pia rs` back into.
- **One-shot agents** — `pia ask "…"` runs a single prompt in an ephemeral container; `pia create` + `pia ask myproj …` reuses a prepared one.
- **Full visibility into what the agent actually does on the network** — see below.
- **Convenience flags** — `--ssh` forwards your SSH agent (private keys never mount), `--docker` gives the agent Docker CLI access to the host daemon for building/testing images (strictly opt-in, root-equivalent).

```bash
bash harness/pia/scripts/build-docker.sh
bash harness/pia/scripts/install-pia.sh    # installs `pia` into ~/.local/bin

pia run myproj -m /path/to/repo --ssh      # interactive agent on a repo
pia ask "Summarize the TODOs in this repo" # one-shot, ephemeral container
pia list                                   # all agent instances
pia stop myproj && pia rs                  # stop, then resume the last session
```

**Watching an agent (`pia monitor`, `pia urls`).** Trust, but verify: a passive `tshark` capture inside each container shows *where the agent's requests actually go* — live with `pia monitor` (destinations plus CPU/memory/net per sample), or retrospectively with `pia urls`, which reports every destination the container has called since it was created, surviving stop/start cycles. HTTPS exposes the hostname (SNI); cleartext HTTP — your traffic to the local proxies on 8086/8087/8088 — shows full URLs. The monitor itself logs nothing.

The rest of the `pia` surface is routine lifecycle management: `create`, `start/run`, `stop`, `remove`, `restart`, `exec`, `sh`, `clean`, plus `keep`/`unkeep`/`rename` to protect a session container from cleanup. Full command reference, monitor internals, and Docker-socket caveats: [harness/pia/README.md](harness/pia/README.md).

### Templates (`templates/`)

- [llm-wiki](templates/llm-wiki/) — a template for LLM-assisted knowledge bases: an idea file you hand to any coding agent, plus the wiki spec and conventions it should maintain.

## Quick Start

Each service is built and run with its own scripts (Docker required):

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

To run the Pi agent container itself, see the [Pi harness](#pi-harness-harnesspia--run-agents-safely-in-containers) section above: build the image, run `install-pia.sh`, then `pia run myproject -m /path/to/repo`.

## Development

Each server ships scripts for its whole lifecycle — `build-docker.sh`, `run-docker.sh`, `pause-docker.sh`, `stop-docker.sh`, `lint-project.sh` (ruff/pyright), `test-project.sh` (unittest), `coverage-project.sh` (coverage.py with a per-server `fail_under` gate), `clean-project.sh`. Tests are plain `unittest` and import the server module directly; no server needs to be running:

```bash
cd servers/github-proxy && python3 -m unittest tests.test_server -v
```

## Documentation

[AGENTS.md](AGENTS.md) is the full project reference — architecture, directory layout, per-server technical details, development conventions, and security notes. It (and this repo) is written to be read by both humans and agents.

## Security Notes

- All credentials live in `secrets/` directories, which are gitignored; only `.gitkeep` files are committed.
- Every proxy rejects non-whitelisted endpoints by default.
- Docker Compose binds all ports to `127.0.0.1` — nothing is exposed to the network.

## License

Released under the [MIT License](LICENSE).
