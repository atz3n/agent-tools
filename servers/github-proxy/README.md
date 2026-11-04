# GitHub API Proxy

A lightweight HTTP proxy that exposes a subset of endpoints from the GitHub REST API. Runs locally and injects your PAT for authentication.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/repos/{owner}/{repo}/pulls` | List PRs |
| POST | `/repos/{owner}/{repo}/pulls` | Create PR |
| GET | `/repos/{owner}/{repo}/pulls/{number}` | Get PR |
| PATCH | `/repos/{owner}/{repo}/pulls/{number}` | Update PR |
| DELETE | `/repos/{owner}/{repo}/pulls/{number}` | Delete PR |
| GET | `/repos/{owner}/{repo}/pulls/{number}/comments` | List review comments |
| POST | `/repos/{owner}/{repo}/pulls/{number}/comments` | Create review comment |
| GET | `/repos/{owner}/{repo}/pulls/{number}/comments/{id}` | Get review comment |
| PATCH | `/repos/{owner}/{repo}/pulls/{number}/comments/{id}` | Update review comment |
| GET | `/repos/{owner}/{repo}/pulls/{number}/comments/{id}/replies` | Get replies to a review comment |
| GET | `/repos/{owner}/{repo}/pulls/comments` | List repository-wide review comments |
| GET | `/repos/{owner}/{repo}/pulls/comments/{id}/reactions` | List reactions for a review comment |
| POST | `/repos/{owner}/{repo}/pulls/comments/{id}/reactions` | Create a review comment reaction |
| DELETE | `/repos/{owner}/{repo}/pulls/comments/{id}/reactions/{reaction_id}` | Delete a review comment reaction |
| GET | `/repos/{owner}/{repo}/pulls/{number}/reviews` | List reviews |
| POST | `/repos/{owner}/{repo}/pulls/{number}/reviews` | Create review |
| GET | `/repos/{owner}/{repo}/pulls/{number}/reviews/{id}` | Get review |
| PUT | `/repos/{owner}/{repo}/pulls/{number}/reviews/{id}` | Update review |
| DELETE | `/repos/{owner}/{repo}/pulls/{number}/reviews/{id}` | Delete pending review |
| PUT | `/repos/{owner}/{repo}/pulls/{number}/reviews/{id}/dismissals` | Dismiss review |
| POST | `/repos/{owner}/{repo}/pulls/{number}/reviews/{id}/events` | Submit review |
| GET | `/repos/{owner}/{repo}/pulls/{number}/reviews/{id}/comments` | List comments for a review |
| PUT | `/repos/{owner}/{repo}/pulls/{number}/merge` | Merge PR |
| GET | `/repos/{owner}/{repo}/pulls/{number}/commits` | List PR commits |
| GET | `/repos/{owner}/{repo}/pulls/{number}/files` | List PR changed files |
| GET | `/repos/{owner}/{repo}/commits/{sha}/pulls` | List PRs with commit |
| PUT | `/repos/{owner}/{repo}/pulls/{number}/update-branch` | Update PR branch |
| GET | `/repos/{owner}/{repo}/issues` | List issues |
| POST | `/repos/{owner}/{repo}/issues` | Create issue |
| GET | `/repos/{owner}/{repo}/issues/{number}` | Get issue |
| PATCH | `/repos/{owner}/{repo}/issues/{number}` | Update issue (close via `state: closed`) |
| GET | `/repos/{owner}/{repo}/issues/{number}/comments` | List issue/PR discussion comments |
| POST | `/repos/{owner}/{repo}/issues/{number}/comments` | Create issue/PR discussion comment |
| GET | `/repos/{owner}/{repo}/issues/{number}/comments/{id}` | Get issue/PR discussion comment |
| PATCH | `/repos/{owner}/{repo}/issues/{number}/comments/{id}` | Update issue/PR discussion comment |
| DELETE | `/repos/{owner}/{repo}/issues/{number}/comments/{id}` | Delete issue/PR discussion comment |
| GET | `/repos/{owner}/{repo}/issues/{number}/labels` | List labels on an issue |
| POST | `/repos/{owner}/{repo}/issues/{number}/labels` | Add labels to an issue |
| PUT | `/repos/{owner}/{repo}/issues/{number}/labels` | Replace all labels on an issue |
| DELETE | `/repos/{owner}/{repo}/issues/{number}/labels` | Remove all labels from an issue |
| DELETE | `/repos/{owner}/{repo}/issues/{number}/labels/{name}` | Remove a label from an issue |
| GET | `/repos/{owner}/{repo}/issues/{number}/assignees` | Check assignee |
| POST | `/repos/{owner}/{repo}/issues/{number}/assignees` | Add assignees |
| DELETE | `/repos/{owner}/{repo}/issues/{number}/assignees` | Remove assignees |
| GET | `/repos/{owner}/{repo}/labels` | List repository labels |
| GET | `/user` | Get authenticated user |

All other endpoints return **403 Forbidden**.

> **Note:** The method column documents the expected HTTP method for each GitHub API endpoint. The proxy accepts all HTTP methods and forwards them — it does not enforce method restrictions.

> **Note:** GitHub has no `DELETE` endpoint for issues — "deleting" an issue means closing it via `PATCH` with `{"state": "closed"}`.

## Architecture

```
Client → :8086 (proxy) → api.github.com
         ↑ token injected  exposes PR + issue endpoints only
         from env var
```

## Getting started

1. Get a personal access token and store it in `./secrets/github-personal-access-token.txt`
2. Build the proxy image: `./scripts/build-docker.sh`
3. Run the containers: `./scripts/run-docker.sh`

The proxy is reachable at `http://localhost:8086`.

## Docker scripts

| Script | Description |
|--------|-------------|
| `./scripts/build-docker.sh` | Build the proxy image |
| `./scripts/run-docker.sh` | Start the containers (auto-exports the token) |
| `./scripts/pause-docker.sh` | Pause without removing containers |
| `./scripts/stop-docker.sh` | Stop and remove containers |
| `./scripts/lint-project.sh` | Lint with ruff and pyright |
| `./scripts/test-project.sh` | Run the unittest suite |
| `./scripts/coverage-project.sh` | Run tests with coverage (fails below `fail_under`; `--html` for report) |
| `./scripts/clean-project.sh` | Remove caches and build artifacts |

## Token management

The token is read from `./secrets/github-personal-access-token.txt` by the Docker scripts and exported as `GITHUB_PERSONAL_ACCESS_TOKEN` to the proxy container.

To rotate the token:

1. Update `./secrets/github-personal-access-token.txt`
2. Restart: `./scripts/stop-docker.sh && ./scripts/run-docker.sh`

## Test

### Unit tests

Run the full test suite:

```bash
cd servers/github-proxy
python3 -m unittest tests.test_server -v
```

Tests cover:
- **Endpoint whitelist** — all PR CRUD, reviews, comments, comment replies, reactions, merge, metadata endpoints
- **Issue whitelist** — issue CRUD, comments, labels, assignees, repository labels
- **Blocked endpoints** — repos, branches, commits, users, search, notifications, milestones, etc.
- **Query parameter stripping** — paths with `?state=open` etc. match correctly
- **Configuration** — TARGET, PORT, TOKEN from env
- **Logging** — format, timestamp, client IP

### Manual test

```bash
# List PRs (should work)
curl http://localhost:8086/repos/octocat/Hello-World/pulls

# List issues (should work)
curl http://localhost:8086/repos/octocat/Hello-World/issues

# Non-PR/issue endpoint (should return 403)
curl http://localhost:8086/repos/octocat/Hello-World/branches
```

## Agent Skills

Three skill files are included so an agent can use the proxy directly. All teach the agent to call the proxy via `curl` to `localhost:8086` — no MCP JSON-RPC or SSE parsing needed, just standard REST calls.

### Docker networking (auto-detection)

When the agent runs inside a Docker container, `localhost` points to the container itself, not the host. Both skill files include an auto-detection snippet that checks for `.dockerenv` and cgroup markers, then sets `PROXY` to `http://host.docker.internal:8086` when appropriate.

If you use a custom setup (e.g., WSL2, VM-based containers), you may need to adjust the detection logic or set `PROXY` manually.

### `skills/github-proxy/github-create-pull-request/SKILL.md`

For PR lifecycle operations:

- **Getting the current user** — `GET /user` to resolve `{owner}`
- **PR operations** — list, create, get, update, delete, merge
- **Metadata** — list files, commits, update branch
- **PR discussion comments** — list via the issues API (`/issues/{n}/comments`)

### `skills/github-proxy/github-review-pull-request/SKILL.md`

For review operations:

- **Getting the current user** — `GET /user` to resolve `{owner}`
- **Reviews** — create, list, submit, update, dismiss, delete pending
- **Review comments** — list and create line-specific comments
- **PR discussion comments** — list discussion comments via the issues API (`/issues/{n}/comments`)

### `skills/github-proxy/github-manage-issues/SKILL.md`

For issue lifecycle operations:

- **Getting the current user** — `GET /user` to resolve `{owner}`
- **Issue operations** — list, create, get, update (close/reopen)
- **Comments** — list, create, get, update, delete issue comments
- **Labels** — list/add/remove/replace labels on an issue, list repository labels
- **Assignees** — check, add, remove assignees

### Using the skills in harnesses

To make the skills available to an agent, copy the skill directories into the agent's skills path, `~/.pi/agent/skills/`, preserving the feature subfolder:

```bash
# copy all three skills
mkdir -p ~/.pi/agent/skills/github-proxy
cp -r skills/github-proxy/github-create-pull-request ~/.pi/agent/skills/github-proxy/
cp -r skills/github-proxy/github-review-pull-request ~/.pi/agent/skills/github-proxy/
cp -r skills/github-proxy/github-manage-issues ~/.pi/agent/skills/github-proxy/
```

The skills will then be automatically discovered by the agent on every conversation. To verify they loaded:

```bash
ls ~/.pi/agent/skills/github-proxy/github-create-pull-request/SKILL.md
ls ~/.pi/agent/skills/github-proxy/github-review-pull-request/SKILL.md
ls ~/.pi/agent/skills/github-proxy/github-manage-issues/SKILL.md
```

If you keep this repo's skills elsewhere, symlink the feature folder instead:

```bash
ln -s "$(pwd)/skills/github-proxy" ~/.pi/agent/skills/github-proxy
```
