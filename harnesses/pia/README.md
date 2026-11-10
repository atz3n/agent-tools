# Pia

Containerized [Pi Coding Agent](https://pi.dev) for isolated, interactive operation — like talking to an agent in your terminal.

## Quick Start

### Build

```bash
bash scripts/build-docker.sh
```

To force a completely fresh build that ignores all cached Docker layers, pass
`--force` (alias `--no-cache`):

```bash
bash scripts/build-docker.sh --force
```

## Multi-Instance Manager (`pia`)

The `pia` CLI lets you run multiple pi-agent containers in parallel, each with its own name.

### Usage

| Command | Description |
|---------|-------------|
| `pia run [NAME]` | Start a new agent container (auto-names if omitted) |
| `pia run -m /path` | Start with `/path` mounted into `/workspace` |
| `pia run --ssh` | Start with host SSH agent socket mounted |
| `pia run --docker` | Start with host Docker socket mounted (opt-in) |
| `pia run myproj -m . --ssh` | Start with name, mount, and SSH |
| `pia create [NAME] [OPTIONS]` | Create a stopped container without starting it (same options as `pia run`) |
| `pia stop [NAME]` | Stop a named container |
| `pia remove [NAME]` / `pia rm [NAME]` | Stop and remove a named container |
| `pia list` / `pia ls` | List all agent containers |
| `pia clean` | Remove all stopped agent containers (kept `pia-keep-*` containers are never removed) |
| `pia resume` / `pia rs` | Start the most recently stopped agent container and jump straight into its last pi session |
| `pia ask [NAME] <prompt>` | One-shot non-interactive pi prompt (`pi --print`); omit NAME for an ephemeral container |
| `pia restart [NAME] -m /path` | Stop/remove then run fresh |
| `pia exec [NAME] [CMD]` | Execute a command in a running container |
| `pia sh [NAME]` / `pia shell [NAME]` | Open an interactive bash shell in a running container (NAME may be omitted if only one is running) |
| `pia monitor [NAME]` | Live view of where the container's requests go, plus CPU/memory/net (terminal only, the monitor itself logs nothing) |
| `pia urls [NAME]` | Every destination/URL the container has called **since it was created** (aggregated; `--all` for every request) |
| `pia keep [NAME] [SUFFIX]` | Protect a container from `pia clean` (renames it to `pia-keep-*`) |
| `pia unkeep [NAME]` | Remove the keep protection (renames it back to `pia-*`) |
| `pia rename [NAME] [NEW]` | Rename a container (running or stopped) |

### Naming

- If no `NAME` is provided, a random name is generated: `pia-XXXXXXXX` (8 random alphanumeric characters)
- You can assign any name: `pia run my-project` (prefix `pia-` is added automatically)
- `pia list` shows all containers matching the `pia-` prefix (or the `pia` project label)
- Kept containers carry the `pia-keep-` prefix — `pia clean` skips them, `pia list` still lists them

### Container Project

Docker has no project concept of its own — a "project" is just a container
label, `com.docker.compose.project`. `pia` stamps it with plain
`docker create/run --label`; compose is never called and no compose file is
involved. All agent instances then group under a single **pia** project, the
same way the `tasks-server` containers group:

```bash
# plain docker filter — the primary way to see the project
docker ps -a --filter label=com.docker.compose.project=pia

# project views also pick it up
docker compose ls
# NAME                STATUS          CONFIG FILES
# pia                 running(2)      N/A
# tasks-server        running(1)      /path/to/agent-tools/servers/tasks-server/docker/docker-compose.yml
```

Each instance additionally carries:

| Label | Value | Why |
|-------|-------|-----|
| `com.docker.compose.project` | `pia` | the project name the views group by |
| `com.docker.compose.service` | container suffix (`pia-backend-api` → `backend-api`) | keeps instances distinguishable inside the project |
| `com.docker.compose.config-hash` | per-container hash | project views ignore containers without it |
| `com.docker.compose.oneoff` | `False` | one-off containers are hidden from project views |

`CONFIG FILES` shows `N/A` for the project because there is no compose file — that is expected, and `docker compose ls` prints one warning line about the missing label. Nothing else consumes it: `pia`, `docker ps`, and Docker Desktop work as usual.

`pia ls`, `pia clean`, and `pia rs` match containers by the `pia-` name prefix **or** this label, so containers started before the labels existed are still listed.

### Examples

```bash
# Start with auto-generated name
pia run
# → pia-k3m9x2p1

# Start with custom name
pia run backend-api
# → pia-backend-api

# Start with mount and SSH
pia run myproj -m /path/to/project --ssh

# Start with Docker access (build/run/test images from inside the agent)
pia run myproj -m /path/to/project --docker

# Create a stopped container now (name + mount set up), use it later with 'pia ask'
pia create myproj -m /path/to/project
pia ask myproj Summarize the open tasks in /workspace

# List all containers
pia list
# → pia-k3m9x2p1      running    5 minutes ago
# → pia-backend-api   stopped    2 hours ago

# Interact with a running container
pia exec myproj ls /workspace
pia exec myproj        # opens interactive shell
pia sh myproj          # interactive bash shell (same thing, dedicated command)
pia sh                 # shell in the only running container

# Stop and remove
pia stop myproj
pia remove myproj

# Remove all stopped agent containers at once (kept containers are preserved)
pia clean

# Restart fresh with a mount
pia restart myproj -m . --ssh

# Resume the latest stopped container and continue its last pi session
pia rs

# One-shot non-interactive prompt (ephemeral container, removed afterwards)
pia ask "Summarize the TODOs in this repo"

# One-shot prompt inside a named container (started if stopped, session kept)
pia ask myproj Summarize the open tasks

# Protect a session container from 'pia clean' (renames pia-myproj -> pia-keep-myproj)
pia keep myproj

# Keep under an explicit name (-> pia-keep-my-session)
pia keep myproj my-session

# Remove the protection (-> pia-myproj)
pia unkeep myproj

# Rename a container
pia rename old-name new-name
```

### Options

| Option | Description |
|--------|-------------|
| `-m, --mount <dir>` | Mount the specified directory into `/workspace` |
| `-s, --ssh` | Mount the host SSH agent socket into the container |
| `--docker` | Mount the host Docker socket into the container (opt-in, see below) |
| `-h, --help` | Display help message |

Monitor options (`pia monitor`):

| Option | Description |
|--------|-------------|
| `-i, --interval <sec>` | Seconds per resource sample (default `3`); with `--raw`, the length of one capture chunk (default `5`) |
| `--raw` | Stream destination lines continuously, without the resource summary |
| `-h, --help` | Display help message |

URL-history options (`pia urls`):

| Option | Description |
|--------|-------------|
| `-a, --all` | Print every logged request in order, without aggregation |
| `-h, --help` | Display help message |

### Notes

- Containers are named with the `pia-` prefix — `pia run` starts an existing stopped container or creates a new one
- `pia create` accepts the same options as `pia run` (`-m`, `--ssh`, `--docker`) but only creates the container and leaves it stopped; it fails if a container with that name already exists. Start it later with `pia run <NAME>` or run a one-shot prompt with `pia ask <NAME> <prompt>` (which starts the container, runs the prompt, and stops it again)
- `pia resume` / `pia rs` start the most recently stopped container (by stop time, not creation time) and attach pi with `--continue`, so you land directly in the last session instead of reopening it; `pia run <NAME>` on a stopped container does the same for that container
- `pia resume` selects the container itself and **takes no name** — `pia rs myproj` is rejected with a hint to use `pia run myproj`, rather than silently resuming a different session
- `pia list` and `pia clean` **take no arguments** — an argument is rejected instead of ignored, so `pia clean --help` prints usage rather than removing containers
- `pia ask` runs `pi --print` through `docker exec` (no TTY needed); in a named container the exchange is saved as a session you can later open with `pia rs`
- `pia sh` (alias `pia shell`) opens `/bin/bash` in a *running* container for manual work; it uses a real TTY when you have one, and when `NAME` is omitted it picks the only running agent container (otherwise it asks for a name)
- `pia monitor` reads the same "only running container" fallback as `pia sh`; it ends by itself if the container goes away, and it stops the capture inside the container when it ends — by Ctrl-C or otherwise (the URL logger that backs `pia urls` is deliberately *not* stopped — it runs for the container's whole life)
- `pia urls` reads the request log the container's entrypoint keeps from creation onwards; it works any time, for the container's whole life (see [Request History](#request-history-pia-urls))
- `pia ask` treats its first argument as a container `NAME` only if that container exists; otherwise the whole argument list is the prompt
- `pia remove` (alias `pia rm`) is the only command that removes a running container; `pia clean` removes only stopped ones, and never removes kept (`pia-keep-*`) containers
- `pia keep` / `pia unkeep` / `pia rename` work on running and stopped containers alike (they only rename, never stop or remove)
- Sessions are stored inside the container — deleting the container deletes the session
- `pia` forwards the OpenRouter key into containers **only when you pass `--openrouter` (`-o`)** — by default containers start with no credentials, even when a key is available on the host (see [Inference via OpenRouter](#inference-via-openrouter))
- Options can be placed before or after the name (e.g., `pia run -m /path myproj` or `pia run myproj -m /path`)
- Containers are labelled with the `pia` project (see [Container Project](#container-project)); `pia list`, `pia clean`, and `pia rs` match them by the `pia-` name prefix or by that label

## Watching a Container (`pia monitor`)

`pia monitor` answers two questions about a running agent container: **where do its
network requests go**, and **what is it costing**. It prints to the terminal and
the monitor itself writes nothing — no log file in the container, none on the
host. (The container separately keeps a destination log for `pia urls`; the
monitor neither reads nor writes it.)

```bash
pia monitor                  # the only running container, 3-second samples
pia monitor myproj -i 10     # a named container, 10-second samples
pia monitor myproj --raw     # just the destination lines, streaming
```

Each sample prints the destinations seen in that interval, then one resource line:

```
14:03:11  TLS   api.anthropic.com (142.250.72.1)   x3
14:03:13  HTTP  GET localhost:8088/tasks?status=open
14:03:14  TLS   registry.npmjs.org (104.16.0.0)
-- cpu 4.2% of 8 core(s)  mem 300.0MiB/2.0GiB (14.6%)  pids 12  net -12.0KiB +4.0KiB  [3s]
```

How it works: `docker exec` runs `pia-monitor` inside the container (from
`docker/monitor-inside.sh`), which captures with `tshark` on the container's own
interface and reads CPU/memory/pids from the container's cgroup files plus
`/proc/net/dev`. Repeated hits to the same destination within an interval collapse
to a single line with an `xN` counter. Stop with `Ctrl-C`.

Every pass is a separate `docker exec`, and `--raw` is no exception: it runs the
capture in chunks (`-i`, default 5 seconds). That is what lets the command notice a
container that stopped (one endless `docker exec` would simply hang), and it bounds
what an interrupted monitor can leave behind — which it does not leave anyway,
because `pia monitor` stops `pia-monitor` inside the container on its way out
(`docker exec` without a TTY forwards no signals, so nobody else would; the helper's
own signal handler then stops the `tshark` it owns). Memory prints as
`used/unlimited` when the container has no memory limit — there is no percentage to
show in that case.

**The chunk boundary, measured.** Restarting a capture costs a blind window at every
chunk boundary — `docker exec` setup, the helper's own startup, and tshark's start.
Measured with 100 TLS handshakes at roughly 5 per second, comparing what `--raw`
printed against a gapless reference capture of the same traffic:

| Chunk | Handshakes seen (of 100) |
|-------|--------------------------|
| one long capture (not an option) | 97 — nothing is missed after its own start |
| `-i 10` | 97 — indistinguishable from no chunking |
| `-i 5` (default) | 88 — about 0.5 s blind per boundary |

What a chunk bounds is *not* `Ctrl-C`: the terminal signals the whole foreground
group, so the in-flight `docker exec` dies with it and the monitor is gone in about
**0.3 s** whatever the chunk is (measured at `-i 5` and `-i 10`). A chunk bounds the
quieter cases instead — a signal that reaches only the monitor's shell (`kill <pid>`,
where bash defers its handler until the in-flight exec returns: measured 1.4 s at
`-i 5`, 6.4 s at `-i 10`), the lifetime of an orphaned capture, and how long a wedged
`docker exec` can hang before the loop notices. 5 s sits in the middle of that line;
pass `-i 10` when completeness matters more than those tails.

A single long capture with a host-side liveness watchdog would remove the boundary
entirely — it was rejected for the extra moving parts, since chunking is also what
notices a vanished container.

**No leftovers.** An interrupted monitor leaves nothing running: the host stops the
helper (`pkill -f 'pia-monitor (cycle|raw)'` — deliberately *not* a tshark pattern,
so a tshark the agent runs itself is untouched, and deliberately narrowed to the
monitor's own modes so the long-running `pia-monitor log` URL logger survives), and
the helper kills and **reaps** its own capture.
Stopping is confirmed, not assumed: `pkill` answers as soon as the signal is delivered,
so `pia monitor` probes until the helper is really gone before returning — if something
still refuses to die (a hand-started `pia-monitor` that ignores signals) it says so and
gives the command to stop it, rather than implying the container is clean.
Reaping matters because PID 1 of the agent image is `sleep infinity`, which never
reaps: an unreaped tshark would linger as a `<defunct>` entry and inflate the `pids`
column of every later sample.

The one case the helper cannot handle is being `SIGKILL`ed itself (OOM kill, or a
`kill -9` aimed at it): no handler runs, so the capture is orphaned and keeps running
— but only until its own `-a duration:` expires, which is why the helper is never
started with an unbounded capture. It then lingers as a harmless `<defunct>` entry:
no CPU, no interface held. Bounded chunks are therefore doing double duty — they cap
both how long a *stopped* monitor can take to notice and how long an *orphaned* capture
can run. (The `pia-monitor log` URL logger is the deliberate exception: it owns its
restart loop, runs unbounded by design, and is covered in
[Request History](#request-history-pia-urls).)

| Column | Source | Notes |
|--------|--------|-------|
| `TLS <host> (<ip>)` | TLS ClientHello SNI | the *hostname only* — the URL path of an `https://` request is inside the encrypted envelope and is never visible to a packet capture |
| `HTTP <method> <url>` | cleartext HTTP | full URL, so the local proxies (`8086`/`8087`/`8088`) show in detail |
| `cpu` | `cpu.stat` usage delta | percent of the container's whole CPU allowance (`cores × interval`) |
| `mem`, `pids` | `memory.current`, `pids.current` | container limits shown when set (`unlimited` otherwise) |
| `net` | `/proc/net/dev` delta | bytes received / sent by this container during the interval |

Requirements and caveats:

- Capture needs `CAP_NET_RAW`, which Docker grants to every container — no
  `--cap-add`, no `--privileged`.
- The image must be built with `tshark` and the `pia-monitor` helper. Containers
  created from an older image get a hint to rebuild and `pia restart`. The
  capture tools are the bulk of that rebuild (`tshark` and its dissection
  library add roughly 250MB to the image).
- This is a passive listener: it never touches the traffic, and it works on a
  container that was already running. It cannot see request *contents* — for that
  you would need a man-in-the-middle proxy plus trusted CA and proxy settings, which is
  deliberately not part of `pia`.

## Request History (`pia urls`)

`pia monitor` only shows traffic *while you watch*. `pia urls` answers the
retrospective question instead: **which URLs or destinations has this container
called since it was created?**

```bash
pia urls                   # the only running container
pia urls myproj            # a named container
pia urls myproj --all      # every logged request in order, no aggregation
```

Example output:

```
[INFO] 47 request(s) to 5 destination(s) since the container was created (/var/log/pia-urls.log):
2026-11-04 10:12:03  x33   TLS   api.anthropic.com (142.250.72.1)
2026-11-04 10:12:09  x6    TLS   registry.npmjs.org (104.16.0.0)
2026-11-04 10:15:44  x4    HTTP  GET localhost:8088/tasks?status=open
2026-11-04 10:20:01  x2    HTTP  POST localhost:8086/repos/o/r/pulls
2026-11-04 10:31:57  x2    TLS   api.github.com (140.82.112.6)
```

How it works: the image's **entrypoint starts `pia-monitor log`** — a small
`tshark` logger — every time an idle (pia-managed) container starts. It appends
one line per request to `/var/log/pia-urls.log` on the container's own
filesystem, so the history:

- covers the container from the moment of creation, with no gaps (one
  unbounded capture, restarted only if `tshark` itself dies),
- **survives `pia stop` / `pia run` / `pia rs`** — the log lives in the
  container, like its sessions — and is lost only with `pia remove`,
- is aggregated by `pia urls` into first-seen time + hit count per
  destination; `--all` prints every logged line instead.

Caveats:

- Same visibility rule as the monitor: HTTPS exposes only the **hostname
  (SNI)**, never the URL path; cleartext HTTP (the local proxies) is logged as
  full URLs.
- The log is cleared at container start if it has grown past ~8 MiB (tens of
  thousands of requests).
- `tshark` needs a moment after the container starts to attach to the
  interface, so requests in roughly the first second of a container's life
  can fall outside the history.
- Containers created from an image built before this feature have no log;
  `pia urls` says so and points at `build-docker.sh` + `pia restart`.
- Containers that run a command instead of idling (`docker run pia <cmd>`)
  skip the logger — it starts on the pia-managed keep-alive path only.
- If the logger is `SIGKILLed` its capture lingers until the container stops;
  the next container start brings it back. Nothing else restarts it mid-run.

## Inference via OpenRouter

Pi ships OpenRouter as a **built-in provider** — nothing has to be added to
`configs/models.json` (which only defines the local `lm-studio` and `mlx-serve`
providers). Pi only needs the API key in its environment — but `pia` does **not**
forward it by default: containers should not carry credentials they do not use
(e.g. when inference runs against a local model). Pass `--openrouter` (`-o`) to
`pia run` / `pia create` / `pia restart` to opt in; `pia` then resolves the key
for you — put it in an `openrouter-key.txt` file once and you never export
anything.

```bash
# one-time setup — plain key, nothing else.
mkdir -p ~/.pia/secrets && chmod 700 ~/.pia/secrets
# replace YOUR_KEY_HERE with your key first, then run:
echo 'YOUR_KEY_HERE' > ~/.pia/secrets/openrouter-key.txt && chmod 600 ~/.pia/secrets/openrouter-key.txt

pia run myproj -o             # forwards the key; without the flag the container gets none
# inside pi: /model → openrouter → e.g. anthropic/claude-sonnet-4.5
```

With `--openrouter`, `pia` looks for the key, in this order:

1. `OPENROUTER_API_KEY` in the environment (wins if set)
2. `$PIA_OPENROUTER_KEY_FILE`, if you point it at a file explicitly (if that
   file does not exist, `pia` **stops with an error** — it never falls back
   to a different key behind your back)
3. `~/.pia/secrets/openrouter-key.txt` — the standard location. `install-pia.sh`
   creates the `~/.pia/secrets/` folder; you place the key file there yourself

Without `--openrouter`/`-o` none of this happens — no key is read, exported or
forwarded, even when `OPENROUTER_API_KEY` is set on the host. `pia ask` takes
no flags and never forwards the key; to ask an OpenRouter-powered container,
`pia create myproj --openrouter` first, then `pia ask myproj <PROMPT>`.

The key is passed to docker **by name only** (never as `-e VAR=value`), so it
never appears in the `docker run` command line in `ps` or the debug log. Inside
the container, pick a model with `/model` (OpenRouter models look like
`openrouter/anthropic/claude-sonnet-4.5`); with a key, Pi lists only the models
that key may use.

Alternatives, and caveats:

- **`/login openrouter`** inside a container stores the key in the container's
  `auth.json`. It survives `pia stop` / `pia rs` of that same container, but a
  **new** container starts clean — the key-file route works for every instance.
- **Default model**: to make OpenRouter the default instead of the local
  `mlx-serve` model, set `defaultProvider`/`defaultModel` in
  `configs/settings.json` (e.g. `"openrouter"` +
  `"anthropic/claude-sonnet-4.5"`) and rebuild the image — or just pick it with
  `/model` per session.
- The key lives in the container's environment, so it is visible in
  `docker inspect` output for that container — another reason forwarding stays
  opt-in (`--openrouter`).
- With `pia monitor`/`pia urls` you can verify the agent only talks to
  `openrouter.ai` when using this provider.

## Docker Access (`--docker`)

The pia image ships the **Docker CLI and the Docker Compose plugin** (no daemon), so
`docker compose` is available inside the container. With `pia run --docker`, the
host Docker socket is mounted into the container, so the agent can build, run, and
test images against the **host daemon** (the "docker-out-of-docker" / socket-passthrough
pattern).

```bash
pia run myproj -m /path/to/project --docker
# inside the container:
docker build -t myimage /workspace       # build context is streamed — works
docker push myimage                      # registry ops — fine
docker run --rm myimage pytest           # fine (no bind mounts)
docker compose -f docker-compose.yml up -d   # subject to the bind-mount caveat below
```

### What works / what to watch

- **Works**: `docker build` (the CLI tars and streams the context, so container paths
  like `/workspace` are fine), `pull`, `push`, `save`, `load`, `cp`, `run` without bind
  mounts, and a build cache shared with the host.
- **Bind mounts are resolved by the host daemon**, not by pia: `-v /workspace/data:/data`
  fails because `/workspace` only exists inside the container. To share data with
  sibling containers use named volumes (`-v mydata:/data`, moved in/out with
  `docker cp` if needed) or bake fixtures into the image.
- **Sibling containers**, not children: they don't see pia's network namespace — reach
  them via a user-defined network or container IP, not `localhost`.
- **Docker Compose** (the `docker compose` plugin, shipped in the image) talks to
  the same host daemon, so the bind-mount and networking caveats above apply to compose
  files too: relative `volumes:` in a compose file inside the container resolve to paths
  the host daemon cannot see. Use named volumes instead.
- **Security**: access to the Docker socket is root-equivalent on the host. That is why
  this is strictly opt-in and not enabled by `pia run` defaults.
- **Rootless Docker on the host**: point at a different socket with
  `DOCKER_SOCKET=~/.docker/run/docker.sock pia run myproj --docker`.

## Make Scripts Globally Accessible

Run the install script to copy `pia` into `~/.local/bin/` (without the `.sh` suffix):

```bash
bash scripts/install-pia.sh
```

Make sure `~/.local/bin` is in your `PATH` (it usually is by default). Then you can call `pia` from anywhere.

## Testing

The test suite uses real Docker containers for some commands (`clean`, `resume`), which can be slow. Filter to specific commands to speed up development:

```bash
cd scripts

# Run all tests (includes slow Docker container tests)
bash run-tests.sh

# Run only specific command tests (skips slow Docker tests)
bash run-tests.sh run stop
bash run-tests.sh clean resume
bash run-tests.sh keep unkeep rename

# Run multiple command tests in one pass
bash run-tests.sh run stop remove list restart exec sh clean resume keep unkeep rename
```

No arguments runs all tests. Arguments filter to only those commands — you can pass multiple command names.

Test containers (`pia-test-*`, `pia-keep-test-*`, and friends) are cleaned up automatically when the runner exits — even if a test fails, times out, or the run is interrupted. Real containers (`pia-<name>`, `pia-keep-<name>`) are never touched.

Cleanup is registry-driven: each test registers the exact container names it creates via `register_test_container` (into a per-run file, `/tmp/pia-test-containers-$$`), including auto-generated names parsed from `pia run` output — so even random-named containers are removed by exact name. The name-pattern sweep remains only as a last-resort fallback for unregistered leftovers.
