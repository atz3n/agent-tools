# Pia

Containerized [Pi Coding Agent](https://pi.dev) for isolated, interactive operation — like talking to an agent in your terminal.

## Quick Start

### Build

```bash
bash scripts/build-docker.sh
```

Builds both images: the agent image (`pia`) and the nested-daemon image
(`pia-dind:guard-v<N>`, built from `docker/pia-dind/` on top of the
upstream `docker:29-dind` — it carries the nested-container guard and its
jq parser). This is the only place either image is built; the `pia` CLI
never builds, it requires both to exist.

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
| `pia run --docker` | Start with a throwaway sibling Docker daemon (opt-in; no host socket) |
| `pia run --docker-full` | Start with the HOST Docker socket mounted (host-root-equivalent!) |
| `pia run myproj -m . --ssh` | Start with name, mount, and SSH |
| `pia create [NAME] [OPTIONS]` | Create a stopped container without starting it (same options as `pia run`) |
| `pia stop [NAME]` | Stop a named container |
| `pia remove [NAME]` / `pia rm [NAME]` | Stop and remove a named container |
| `pia list` / `pia ls` | List all agent containers |
| `pia clean` | Remove all stopped agent containers (kept `pia-keep-*` containers are never removed) |
| `pia resume` / `pia rs` | Start the most recently stopped agent container and jump straight into its last pi session |
| `pia ask [NAME] <prompt>` | One-shot non-interactive pi prompt (`pi --print`); omit NAME for an ephemeral container |
| `pia restart [NAME] [OPTIONS]` | Restart a named container, continuing its last pi session — unchanged/omitted flags resume in place, changed flags re-create but carry the conversation over, `--fresh` forces a recreate with a clean session |
| `pia exec [NAME] [CMD]` | Execute a command in a running container |
| `pia sh [NAME]` / `pia shell [NAME]` | Open an interactive bash shell in a running container (NAME may be omitted if only one is running) |
| `pia monitor [NAME]` | Live view of where the container's requests go, plus CPU/memory/net — drawn as charts on a terminal, one line per sample when piped (terminal only, the monitor itself logs nothing) |
| `pia urls [NAME]` | Every destination/URL the container has called **since it was created** (aggregated; `--all` for every request) |
| `pia dindlog [NAME]` | Nested-container guard refusals of the agent's throwaway Docker daemon (works even after a kill-switch exit) |
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

# Start with Docker access (build/run/test images from inside the agent) —
# a private, throwaway daemon per session; the host socket stays invisible.
# '--docker-dev' also mounts the workspace into that daemon, so bind
# mounts and compose configs resolve (see the Docker Access section).
pia run myproj -m /path/to/project --docker
pia run myproj -m /path/to/project --docker-dev

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

# Restart keeping the pi conversation: unchanged flags resume in place,
# changed flags re-create the container but restore the session ('pi --continue')
pia restart myproj -m . --ssh

# Force a recreate with a clean pi session
pia restart myproj --fresh

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
| `--docker` | Throwaway sibling Docker daemon per session (safe default, see below). Grants the agent root over the session — use it for your own code only |
| `--docker-dev` | `--docker` plus the `-m` workspace mounted into the daemon at the same path (requires `-m`) |
| `--docker-full` | Mount the raw **host** Docker socket — host-root-equivalent by design (loud banner, refused by `pia ask`) |
| `-h, --help` | Display help message |

Monitor options (`pia monitor`):

| Option | Description |
|--------|-------------|
| `-i, --interval <sec>` | Seconds per resource sample (default `1`); with `--raw`, the length of one capture chunk (default `5`). `-i 5` makes for a calmer chart |
| `--raw` | Stream destination lines continuously, without the resource summary |
| `--chart` | Draw the chart dashboard even when stdout is not a terminal (escape codes then go into the pipe too — mostly for testing it) |
| `--no-chart` | One line per sample, even on a terminal |
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
- `pia list` takes no arguments except `-a`/`--all` (which also shows the throwaway `NAME-dind` daemon containers, hidden by default); `pia clean` **takes no arguments** — an argument is rejected rather than ignored, so `pia clean --help` prints usage instead of removing containers
- `pia ask` runs `pi --print` through `docker exec` (no TTY needed); in a named container the exchange is saved as a session you can later open with `pia rs`
- `pia sh` (alias `pia shell`) opens `/bin/bash` in a *running* container for manual work; it uses a real TTY when you have one, and when `NAME` is omitted it picks the only running agent container (otherwise it asks for a name)
- `pia monitor` reads the same "only running container" fallback as `pia sh`; it ends by itself if the container goes away, and it stops the capture inside the container when it ends — by Ctrl-C or otherwise (the URL logger that backs `pia urls` is deliberately *not* stopped — it runs for the container's whole life). It charts on a terminal and prints lines when piped, so `pia monitor proj > log.txt` stays readable
- `pia urls` reads the request log the container's entrypoint keeps from creation onwards; it works any time, for the container's whole life (see [Request History](#request-history-pia-urls))
- `pia ask` treats its first argument as a container `NAME` only if that container exists; otherwise the whole argument list is the prompt
- `pia remove` (alias `pia rm`) is the only command that removes a running container; `pia clean` removes only stopped ones, and never removes kept (`pia-keep-*`) containers
- `pia keep` / `pia unkeep` / `pia rename` work on running and stopped containers alike (they only rename, never stop or remove)
- Sessions are stored inside the container — deleting the container deletes the session
- `pia` never forwards provider credentials into containers — inference runs through [llm-proxy](../../servers/llm-proxy/), which injects keys server-side (see [Inference via llm-proxy](#inference-via-llm-proxy))
- Options can be placed before or after the name (e.g., `pia run -m /path myproj` or `pia run myproj -m /path`)
- `--docker-dev` is `--docker` plus exactly one bind: it **requires** `-m`, mounts that directory into the *daemon* at the same path so nested bind mounts resolve, and recreates the daemon when the workspace changes. `pia ask` accepts it only for ephemeral sessions (see [docs/docker.md](docs/docker.md))
- Containers are labelled with the `pia` project (see [Container Project](#container-project)); `pia list`, `pia clean`, and `pia rs` match them by the `pia-` name prefix or by that label

## Watching a Container (`pia monitor`)

`pia monitor` answers two questions about a running agent container: **where do its
network requests go**, and **what is it costing**. It prints to the terminal and
the monitor itself writes nothing — no log file in the container, none on the
host. (The container separately keeps a destination log for `pia urls`; the
monitor neither reads nor writes it.)

```bash
pia monitor                  # the only running container, 1-second samples
pia monitor myproj -i 10     # a named container, 10-second samples
pia monitor myproj --raw     # just the destination lines, streaming
```

Each sample prints the destinations seen in that interval, then one resource line
(this is the **line view** — what a terminal gets is [the dashboard
below](#the-chart-dashboard), and a pipe always gets these lines):

```
14:03:11  TLS   api.anthropic.com (142.250.72.1)   x3
14:03:13  HTTP  GET localhost:8088/tasks?status=open
14:03:14  TLS   registry.npmjs.org (104.16.0.0)
-- cpu 4.2% of 8 core(s)  mem 300.0MiB/2.0GiB (14.6%)  pids 12  net -12.0KiB +4.0KiB  tok in 262.1k (in 8.2k + cached 254.0k) out 21.5k $0.42  [1s]
```

### The chart dashboard

On a terminal that same sample is **drawn** instead of printed: one frame per
interval, replacing itself in place rather than scrolling.

```bash
pia monitor                      # charts, because stdout is a terminal
pia monitor myproj -i 5          # a calmer frame: one redraw every 5 seconds
pia monitor myproj --no-chart    # the line view above, on a terminal too
pia monitor myproj | tee log.txt # the line view: a pipe gets no escape codes
```

```
 pia-k3m9x2p1                up 01:02:05        pids 12   peak cpu 6.8%/mem 813.0MiB
────────────────────────────────────────────────────────────────────────────────
 cpu  4.2% of 8 cores          ▁▇▁▂▇▁▂▇▁▁
 mem  300.0MiB/2.0GiB (14.6%)  ▇▇▇▇░░░░░░░░░░░░░░░░░░░░
 net  ↓12.0KiB ↑4.0KiB         rx ▁▇▁▁▇▁▁▇▁▁ tx ▁▇▁▁▇▁▁▇▁▁
 tok  in 25.2M (in 1.2M + cached 24M)  out 84k  $2.31

destinations  this cycle: 18   total: 197   targets: 5
 x22   HTTP  GET localhost:8088/tasks?status=open
 x151   TLS   api.github.com (20.205.243.168)
 x7    TLS   api.anthropic.com (142.250.72.1)
 x14   TLS   registry.npmjs.org (104.16.0.0)
 x3    HTTP  POST localhost:8086/repos/x/y/pulls

Ctrl-C to stop · every 1s · -i 5 for a calmer chart · --no-chart for the line view
```

What is on it, and why:

| Part | Shows | Notes |
|------|-------|-------|
| header | name, uptime, current `pids` and the run's **peak cpu/memory** | peaks describe the whole session, so they sit next to the uptime; on a narrow terminal the tail is truncated with `~` rather than wrapped |
| `tok` | the agent's **token usage**, cumulative across **all sessions** the container stores, on its own row under `net` — the input **total** with the uncached + cache-read split in parentheses, and output, like pi's own `/usage`, plus cost when the provider reports one | cached reads and fresh prompt tokens are different money, and the cached side dwarfs the other once a session settles — the row leads with the whole and shows the parts, so nobody does token arithmetic mid-glance. Sessions live on the container's filesystem: the total survives stop/start and `pia resume`, and ends with `pia remove`. The row exists because this figure did not survive a squeezed header |
| `cpu` | newest percent + sparkline of the run | scaled to the run's own maximum, so a container that goes busy after an hour of quiet still lights up — but one step below the top: the highest block is never drawn, so a busy container shows a line with a gap above it, and dips stay visible instead of flattening into a wall |
| `mem` | gauge against the limit | with no limit there is no percentage to gauge, so the row prints `unlimited` and shows the history instead — the same call line mode makes; the run's peak is in the header |
| `net` | newest ↓/↑ deltas + two sparklines | rx and tx are separate series: a download and an upload are not the same story |
| destinations | one row per URL, **most recently called first** (the last sample a destination appeared in), its accumulated hits as the tie-break | what the container is talking to NOW sits on top, and a page the agent stopped looking at sinks; counts still add up across samples, so a polled URL keeps one stable, growing row instead of flickering between `x1` and `x0`. No gauge trails the URL: the count is the whole story, and the freed columns show longer URLs in full |

Three properties worth knowing:

- **The frame lives on the alternate screen** (`ESC[?1049h`), so when the monitor
  ends the terminal is exactly as it was — scrollback included. Nothing is left
  behind visually, just as nothing is left behind in the container.
- **The history is in memory and ends with the monitor.** Sparklines are the
  samples *this* monitor watched, not the container's history: no file is written,
  in chart mode or out of it. For the whole life of the container there is
  [`pia urls`](#request-history-pia-urls).
- **The sample itself is machine-readable.** The helper prints one more line per
  cycle (`#stats cpu=… mem=… rx=… tx=… tok_in=… tok_cache=… tok_out=…`) and the host charts
  *that*, rather than parsing numbers back out of the human summary line. An image built before that
  line existed prints a normal cycle, so the monitor notices, says so once, and
  finishes in the line view — rebuild and `pia restart` to get charts.

`--chart` forces a frame even when stdout is not a terminal. That is what the test
suite uses to drive the renderer without a pty; normally you want the automatic
choice, which keeps pipes and log files free of escape codes.

How it works: `docker exec` runs `pia-monitor` inside the container (from
`docker/pia/monitor-inside.sh`), which captures with `tshark` on the container's own
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
| `mem`, `pids` | `memory.current` − `inactive_file`, `pids.current` | the page cache charged to the cgroup is reclaimable, so it is not counted as used — the same rule `docker stats` applies (without it, a download-heavy spell shows as gigabytes 'in use'); container limits shown when set (`unlimited` otherwise). Never compare with the agent's `/proc/meminfo`: inside a container that is the **host's** memory |
| `net` | `/proc/net/dev` delta | bytes received / sent by this container during the interval |

Requirements and caveats:

- Capture needs `CAP_NET_RAW`, which Docker grants to every container — no
  `--cap-add`, no `--privileged`.
- The image must be built with `tshark` and the `pia-monitor` helper. Containers
  created from an older image get a hint to rebuild and `pia restart`. The
  capture tools are the bulk of that rebuild (`tshark` and its dissection
  library add roughly 250MB to the image). Charts additionally need the helper's
  `#stats` sample line; an image without it still monitors, in the line view.
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

## Inference via llm-proxy (`extensions/llm-proxy.ts`)

All inference goes through the [llm-proxy](../../servers/llm-proxy/) service
(port 8089). One pi provider extension — `extensions/llm-proxy.ts`, baked
into the image at `~/.pi/agent/extensions/` — registers **both** providers;
there is **no `models.json` at all**. Every inference setting lives in that
one file plus two env vars:

| Provider | Registration | Model catalog |
|---|---|---|
| `openrouter` | `baseUrl` **override of pi's built-in provider**, pointed at the proxy's `/openrouter/v1` route | pi's built-in curated catalog — thinking-level maps, `~latest` virtual models, per-key filtering, Anthropic dialect for Claude models. Never copy a model list into the override. |
| `mlx-serve` | native **dynamic** provider on the `/mlx-serve/v1` route | fetched live from mlx-serve's `GET /v1/models` (through the proxy) — loading, renaming or requantizing a local model needs no config edit and no image rebuild; models appear with their real context window, output budget, reasoning and vision flags. |

| Env var (on the container) | Default | Meaning |
|---|---|---|
| `LLM_PROXY_URL` | `http://host.docker.internal:8089` | proxy base URL; the extension appends the route prefixes itself |
| `LLM_PROXY_TOKEN` | *(unset → dummy `"none"`)* | optional shared-secret Bearer sent on every request, both providers — set it to the **same value** as the proxy's `LLM_PROXY_TOKEN` to enable the gate. The proxy validates it, then injects the real OpenRouter key (or strips auth on credential-free routes). |

The extension only ever sends these credentials **to the proxy**, so
**containers carry no inference secrets at all** — `pia` never reads, exports
or forwards any provider key, and `docker inspect` shows none.

```bash
# start the proxy once (needs servers/llm-proxy/secrets/openrouter-api-key.txt)
cd ../../servers/llm-proxy && ./scripts/run-docker.sh

pia run myproj
# inside pi: /model → openrouter → e.g. anthropic/claude-sonnet-4.5,
#            or mlx-serve → a locally loaded model
```

mlx-serve discovery details:

- Only entries with the `chat` capability are listed (FLUX/LTX/TTS models are
  filtered out); ready models sort before unloaded ones — an unloaded model
  still works, mlx-serve loads it on request, the first token just waits for
  the load.
- Refresh timing: the extension fetches once at pi startup (bounded by a 3 s
  timeout, so a down mlx-serve never stalls boot), pi refreshes live catalogs
  at startup and when `/model` searches, and the fetched list is persisted to
  pi's model store — print mode (`pi --print`, used by `pia ask`) never runs
  catalog refreshes itself, so it relies on the persisted list or the
  extension's startup fetch.
- The catalog is live state: `configs/settings.json`'s `defaultModel` must
  name a model id the catalog actually reports (`mlx-serve/<id>`), otherwise
  pi falls back to its own default selection at startup.
- Unit tests: `node --test harnesses/pia/extensions/__test__/` (needs pi
  installed globally; mocks the catalog, no server required).

Caveats:

- **llm-proxy must be up.** With the extension pointing at
  `host.docker.internal:8089`, a stopped proxy means every model fails —
  `servers/llm-proxy/scripts/run-docker.sh`.
- **Default model**: to make OpenRouter the default instead of the local
  `mlx-serve` model, set `defaultProvider`/`defaultModel` in
  `configs/settings.json` and rebuild the image — or just pick with `/model`
  per session.
- With `pia monitor`/`pia urls` you can verify a session only talks to the
  proxy (cleartext, `host.docker.internal:8089`) — never to a provider host
  or with any credential in hand.

## Docker Access (`--docker`)

The pia image ships the **Docker CLI and the Docker Compose plugin** (no daemon).
`pia run --docker` gives the agent a **private, throwaway Docker daemon** so it can
build, run and test images — **without ever seeing the host Docker socket**.

Full reference — architecture diagrams, plumbing, the nested-container guard,
`--docker-dev`, per-host threat model, configuration and troubleshooting:
**[docs/docker.md](docs/docker.md)**.

### Trust ladder (modes)

| Mode | What it is | Threat model it survives |
|------|-----------|--------------------------|
| no `--docker` | no Docker at all | hostile workload, fully contained |
| `--docker` | sibling throwaway daemon `NAME-dind`, one per session, with a nested-container guard | your own builds: credential isolation, and **with sysbox/gVisor** filesystem isolation too. On plain runc (Docker Desktop!) the daemon is privileged and the guard blocks the no-exploit escapes — hostile input still needs kernel/daemon CVEs, so keep it to trusted code |
| `--docker-dev` | same daemon, **plus** the `-m` workspace mounted into it at the same path | your own dev stacks: adds exactly one bind (the workspace); the runtime caveats of `--docker` apply unchanged |
| `--docker-full` | the raw **host** socket mounted | **nothing — host root by design** |

Decision rule: the danger of the input and the strength of the boundary move
together. `--docker-full` sits *below* "no `--docker`"; when in doubt, take
the lower mode. In short:

- `--docker` hands the agent **root inside the session** — the private
  daemon answers over TCP in a shared network namespace; the host socket
  stays invisible and the daemon has no host mounts.
- Every dind daemon runs the **guard**, baked into the
  `pia-dind:guard-v<N>` image and installed by its entrypoint as the
  daemon's own `runc` (spec parsing via jq, fail-closed): refuses
  `--privileged`, dangerous `--cap-add`s, host namespace joins,
  daemon-internal bind mounts and symlink/TOCTOU bind tricks — the routes
  that would otherwise need no exploit to reach host disks or, on Docker
  Desktop, the macOS file-sharing folders.
- **sysbox or gVisor on the host → real boundary** (unprivileged daemon);
  plain runc (Docker Desktop included) → guard + privileged daemon, i.e.
  hostile input now needs a kernel/daemon CVE — untrusted code belongs in a
  session with **no `--docker`** there.
- `--docker-dev` is `--docker` plus exactly one bind: it **requires**
  `-m`, mounts that directory into the *daemon* at the same path so nested
  bind mounts and compose configs resolve, and recreates the daemon when the
  workspace changes. `pia ask` accepts it only for ephemeral sessions.

```bash
pia run myproj -m /path/to/project --docker            # named volumes only
pia run myproj -m /path/to/project --docker-dev   # bind mounts resolve
docker exec pia-myproj-dind cat /var/log/pia-dind-guard.log   # guard refusals
```


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
