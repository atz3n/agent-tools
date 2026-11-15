# How pia Uses Docker

Everything Docker-related in one place: how the agent container itself is
run, how `--docker` gives an agent its own throwaway daemon, how the
nested-container guard polices that daemon, and what the resulting security
posture actually is on each kind of host.

The [README](../README.md) keeps a short summary and the mode table; this
document is the reference.

---

## 1. Where Docker appears in pia

| Surface | What it is | Who controls it |
|---|---|---|
| **The agent container** | Every pia session *is* a Docker container (`pia:latest` image) created and started by the `pia` CLI | the CLI, running as the user, on the host |
| **The dind sibling daemon** | `--docker` / `--docker=dind-dev`: a private, throwaway `pia-dind` container (`NAME-dind`) per session — `docker:29-dind` plus the baked-in policy guard | created and guarded by the CLI; the agent talks to its API over TCP but can never touch the container itself |
| **The host socket (legacy)** | `--docker=socket`: mounts `/var/run/docker.sock` into the agent | the agent, with host-root power — loud banner, refused by `pia ask` |

The agent image ships the **Docker CLI and the Compose v2 plugin only** — no
daemon. Without a `--docker` mode there is no daemon to reach and no socket
to mount: `docker` calls simply fail, which is the fully-contained mode.

---

## 2. The agent container

`pia run`/`pia create`/`pia ask` all end in a `docker create/run` built by
`build_docker_args()` in `scripts/pia.sh`:

| pia option | Docker effect |
|---|---|
| (name) | `--name pia-<name>` (prefix auto-added; `pia-keep-*` containers are never removed by `pia clean`) |
| `-m <dir>` | `-v <resolved-dir>:/workspace` |
| `--ssh` | host SSH agent socket mounted read-only |
| `-o` / `--openrouter` | `-e OPENROUTER_API_KEY=…` (opt-in; never for `pia ask`) |
| `--docker[=dind\|dind-dev]` | `--net container:NAME-dind` + `-e DOCKER_HOST=tcp://127.0.0.1:2375`, no socket mount |
| `--docker=socket` | `-v <DOCKER_SOCKET>:/var/run/docker.sock` |
| (always) | labels: `com.docker.compose.project=pia`, `config-hash=…`, and for daemons `pia-role=dind`, `pia-parent=NAME`, `pia-dind-mounts=<ws>` |

The `pia` project label is stamped with plain `docker --label` — compose is
never called — so `docker ps --filter label=com.docker.compose.project=pia`
groups every session. `pia stop/rm/restart/clean` resolve daemon siblings
through the `pia-parent` label (name convention is only a fallback), so
`stop`/`rm` never leave a daemon behind and `clean` never removes a running
agent's daemon.

---

## 3. Docker access modes (trust ladder)

| Mode | What it is | Threat model it survives |
|------|-----------|--------------------------|
| no `--docker` | no Docker at all | hostile workload, fully contained |
| `--docker` (= `--docker=dind`) | sibling throwaway daemon `NAME-dind`, one per session, with a nested-container guard | your own builds: credential isolation, and **with sysbox/gVisor** filesystem isolation too. On plain runc (Docker Desktop!) the daemon is privileged and the guard blocks the no-exploit escapes — hostile input still needs kernel/daemon CVEs, so keep it to trusted code |
| `--docker=dind-dev` | same daemon, **plus** the `-m` workspace mounted into it at the same path | your own dev stacks: adds exactly one bind (the workspace); the runtime caveats of `--docker` apply unchanged |
| `--docker=socket` | the raw **host** socket mounted (legacy) | **nothing — host root by design** |

Decision rule: the danger of the input and the strength of the boundary move
together. `--docker=socket` sits *below* "no `--docker`"; when in doubt, take
the lower mode. A VM-backed tier (daemon in its own kernel, own VM) is
planned as a v2 follow-up; until it exists, `--docker=vm` is an invalid mode.

`pia ask` (unattended) accepts `--docker` and `--docker=dind-dev` (the latter
only for ephemeral asks, with `-m`) but **refuses `--docker=socket`** — an
unattended session must never hold a host-root credential nobody is watching.
`project-autopilot` must never pass `--docker=socket`.

### Architecture at a glance

```text
                        pia run --docker???
                               │
      ┌──────────────┬─────────┴────────┬────────────────┬
      │ (omitted)    │ --docker         │ --docker=      │ --docker=socket
      │              │                  │     dind-dev   │
      ▼              ▼                  ▼                ▼               
  ┌─────────┐   ┌───────────┐     ┌───────────┐    ┌───────────┐
  │  NONE   │   │   dind    │     │ dind-dev  │    │  LEGACY   │
  │ no      │   │ + guard   │     │ dind +    │    │ ⚠ HOST    │
  │ docker  │   │  default  │     │ exactly 1 │    │   ROOT    │
  └─────────┘   └───────────┘     │   bind    │    └───────────┘
                                  └───────────┘
              (--docker=vm — daemon in its own kernel — is planned v2,
               not implemented; the mode is rejected as invalid)
```

**Mode B — `--docker` (dind, the default).** A sibling daemon per session;
the host socket is never mounted anywhere:

```text
┌─ HOST ────────────────────────────────────────────────────────┐
│  host dockerd (root)   ←— NOBODY in this diagram connects here│
│     ✗ socket never mounted                                    │
│                                                               │
│ ╔═ pia project ════════════════════════════════════════════╗  │
│ ║ ┌──────────────────┐  DOCKER_ ┌───────────────────────┐  ║  │
│ ║ │ pia-foo (agent)  │ ─HOST──▶ │ pia-foo-dind          │  ║  │
│ ║ │ pi + /workspace  │  tcp:    │ dockerd (throwaway)   │  ║  │
│ ║ │ docker CLI only  │  2375    │  guard replaces runc  │  ║  │
│ ║ │ no socket,       │          │  NO host mounts       │  ║  │
│ ║ │ no creds         │          │  images: own storage  │  ║  │
│ ║ └──────────────────┘          └───────────────────────┘  ║  │
│ ║        shared network namespace — 2375 never published   ║  │
│ ╚══════════════════════════════════════════════════════════╝  │
└───────────────────────────────────────────────────────────────┘
  ↑ both are plain containers on the host — "sibling", not nested
  survives: stolen keys, host files, the real docker ✅ (sysbox/gVisor:
  full stop) · plain runc: guard blocks walk-in escapes; a kernel or
  daemon CVE still reaches the shared host ⚠
```

The dind box's *runtime* is a slot, auto-detected at `pia run` time — same
flag, same UX:

```text
   pia-foo-dind runs on:
   ├─ sysbox-runc  (host has sysbox)           → unprivileged daemon    🥇 real boundary
   ├─ runsc        (host has gVisor)           → userspace kernel       🥈 real boundary
   └─ plain runc   (always — e.g. Docker
      Desktop)                                 → --privileged + guard   ⚠ shared kernel
                        (privileged is not optional there: nested
                         containers cannot even start without it — §4)
```

**Mode B′ — `--docker=dind-dev`.** The same daemon plus exactly one bind,
mounted at the *same path* the agent sees — path symmetry is the whole trick:

```text
     HOST                 ┌─ pia-foo (agent) ────────┐
  /home/me/proj ─────────▶│ /workspace  (project)    │
       │ (one host        └──────────────────────────┘
       │  directory)      ┌─ pia-foo-dind ───────────┐
       └─────────────────▶│ /workspace  (SAME dir)   │
                          │ dockerd + guard          │
                          └────────────┬─────────────┘
                                       │ nested: docker run -v /workspace/app:/etc/app
                                       ▼
                          ┌─ nested container ───────┐
                          │ /etc/app = real project  │  bind is rprivate — nested
                          │   files, read+write      │  mounts never flow back
                          └──────────────────────────┘
  cost: nested containers write there as root, and read whatever
  lands there (.env, git creds…) — §6
```

**Mode C — `--docker=socket` (legacy, fenced off).** The original bug, kept
on purpose for the one human-watching use case — loud banner, refused by
`pia ask`/autopilot:

```text
┌─ HOST ────────────────────────────────────────────┐
│   ┌── dockerd (root) ──────────────────┐          │
│   │  can: run anything, mount anything │          │
│   └─────────────▲──────────────────────┘          │
│                 │ /var/run/docker.sock            │
│                 │ ⚠ MOUNTED INTO AGENT ⚠          │
│   ┌─────────────┴──────────────────────┐          │
│   │  pia agent container               │          │
│   │  pi + ANY code it runs             │          │
│   └────────────────────────────────────┘          │
│   agent == host root. Survives: nothing.          │
└───────────────────────────────────────────────────┘
```

**The mental model.** Danger of the input and strength of the boundary move
together:

```text
  HOW MUCH DO YOU TRUST WHAT THE AGENT RUNS?

  own scripts ──► your builds ──► dev stacks ──► third-party ──► hostile
  & nothing       (build/test)    (compose       code            input
                                   + binds)         │              │
      │               │              │             ▼              ▼
      ▼               ▼              ▼          no --docker    no --docker
  no --docker     --docker    --docker=        (or dind on     (or wait
                   (dind)       dind-dev        sysbox/gVisor)   for vm)

  --docker=socket ✗ NOT ON THIS LINE — it sits BELOW "no --docker":
     strictly worse than doing nothing, because it converts "agent
     might be hostile" into "hostile code has root on my machine."
```

---

## 4. The throwaway daemon: lifecycle and plumbing

```
pia-<name> (agent)              pia-<name>-dind (throwaway daemon)
  docker build / compose  ─TCP─►  tcp://127.0.0.1:2375 (shared netns)
  DOCKER_HOST set, no socket      NO host mounts — builds/contexts stream in
                                  pia-dind-guard wraps runc
                                  runtime: sysbox → gVisor → runc (auto-detected)
```

Creation sequence (`start_dind_sibling`, always **before the agent exists**):

1. `detect_dind_runtime()` — `sysbox-runc` → `runsc` → plain runc (`""`).
2. `dind_create_args()` builds the `docker run -d` arguments: project labels,
   `pia-role=dind`, `pia-parent`, `pia-dind-mounts=<workspace>`, the runtime
   (or `--privileged` on plain runc, see below), the optional dind-dev bind,
   `DOCKER_TLS_CERTDIR=` + `dockerd --host=unix:///var/run/docker.sock
   --host=tcp://127.0.0.1:2375 --tls=false`. The TCP port is **loopback**
   inside the daemon's network namespace — the agent
   reaches it there because it joins that netns
   (`--net container:NAME-dind`), but a *nested* container (its own netns,
   reached via the bridge) can no longer dial the API directly; only
   published-port forwarding (docker-proxy, dialing loopback) still works.
   Nothing is ever published on the host.
3. `wait_dind_ready()` — polls `docker exec NAME-dind docker version`.
4. `dind_guard_ok()` — verifies the running daemon may be revived:
   content (guard marker + jq in the effective runc) AND fingerprint
   (created from the current image id — see §5).
5. `harden_dind_toolchain()` — `chattr +i` on the binaries that only exist
   post-startup (the dind machinery downloads containerd during boot).
6. Only then is the agent container created/started.

**Image**: `pia-dind:guard-v<N>` — a thin image built by
`scripts/build-docker.sh` from `docker/pia-dind/` (context = that folder),
`FROM` digest-pinned `docker:29-dind`. The tag IS the guard policy version,
so a policy change means a new tag on the next build and old daemons
recreate. The CLI never builds — the agent image is only obtainable from
the same script, so a usable CLI already implies both were built.
`PIA_DIND_IMAGE` overrides the whole reference: pia pulls it if absent, and
verification is the only gate (see §5).

**Runtime fallback — why plain runc must run privileged.** Verified on
Docker Desktop (linuxkit 7.0.14/arm64, `docker:29-dind`, runc 1.5.2 and
crun 1.31):

- Docker's default seccomp profile answers
  `keyctl(KEYCTL_JOIN_SESSION_KEYRING)` with EPERM (its mitigation for the
  session-keyring kernel CVEs). Seccomp filters are inherited and can only
  be tightened, so **no inner flag can undo it** — every nested `docker run`
  dies with `unable to join session keyring` unless the daemon container
  itself escapes the profile.
- `/proc/sys` is mounted read-only in an unprivileged container, so nested
  **bridge networking** cannot be set up (the per-interface `disable_ipv6`
  sysctl write fails); runc also refuses a `/proc/sys` bind mount by design
  (proc-safety).
- An enumerated-caps configuration was tried first and runs **zero** nested
  containers on such hosts. `--privileged` is the documented upstream dind
  requirement and the only thing that works; pia prints a loud warning when
  it falls back to it. With sysbox/gVisor present the daemon runs
  unprivileged on that runtime instead.

**Revive vs recreate.** Binds are frozen at creation, and a daemon's writable
layer may have been written to by nested workloads, so:

- existing daemon with a **different workspace** → recreated
  (`pia-dind-mounts` label is compared);
- existing daemon **lacking the current guard version** → recreated, never
  revived (its layer can't be trusted);
- otherwise → started as-is (`wait_dind_ready`).

`--docker=dind-dev` details (path symmetry, `rprivate`, root ownership) and
plain-dind caveats (silent empty bind mounts, per-session image cache) are
in sections 6 and 7; residual risks in section 8.

---

## 5. The nested-container guard (`pia-dind-guard`)

The daemon container is root on the shared kernel (privileged on plain-runc
hosts). Without policing what the agent submits to it, a nested
`--privileged -v /dev:/dev` container mounts the host's raw disks with no
exploit at all — and on Docker Desktop the VM's virtiofs shares made the
whole macOS file-sharing set reachable read-write (§8.2). The guard closes
those routes.

**What it is.** A POSIX-sh policy script (`harnesses/pia/docker/pia-dind/guard.sh`,
lint-checked by the test suite) that parses the OCI spec with **jq**
(Alpine's signed jq package is baked into the daemon image; every decision
reads the spec through jq queries, not text patterns, and a missing jq or an
unparsable `config.json` is a refusal, not a fallback). Its policy version
is the `GUARD_VERSION=` marker on line 2; the image tag derives from it, so
there is no second copy to drift. The image entrypoint installs it **as the
daemon's `runc`** — the real binary is moved to `runc.real` — so
*every* nested container create/exec passes through it, including
`docker run --runtime=runc`. It inspects the OCI `config.json` from the
bundle and refuses:

| Refused | Closes |
|---|---|
| `--privileged`; **any capability outside Docker's default allow-list** (`CHOWN DAC_OVERRIDE FOWNER FSETID KILL SETGID SETUID SETPCAP NET_BIND_SERVICE NET_RAW SYS_CHROOT MKNOD AUDIT_WRITE SETFCAP`) | raw-disk mounts, virtiofs mounts, ptrace of dockerd, and the **arbitrary kernel-memory read primitive** a `--cap-add BPF --cap-add PERFMON` container with an unconfined seccomp filter can build (a kprobe `bpf_probe_read_kernel` oracle). A deny-list is unsafe — it misses `BPF`/`PERFMON` and future names; an allow-list refuses every non-default cap by construction (`CHECKPOINT_RESTORE`, `LINUX_IMMUTABLE` — which the `chattr +i` tamper-proofing assumes unreachable — `NET_ADMIN`, …) |
| a spec whose **seccomp** section is omitted, `unconfined`, or not deny-by-default (`defaultAction` must be `SCMP_ACT_ERRNO`/`KILL*`) | `--security-opt seccomp=unconfined` makes moby omit the seccomp section — Docker's default profile blocks `bpf()`/`perf_event_open()`, so an unconfined filter is what lets the kernel-read primitive through. A default-`ALLOW` custom profile is one forgotten syscall from the same hole, so only deny-by-default profiles pass |
| `docker exec --privileged`, and `runc exec -f FILE` whose process config carries a non-default cap | the exec API has a `Privileged` field and `runc exec -f` replaces the process config wholesale — "exec cannot exceed create-time bounds" is **false**; both channels are policed (a normal exec carries the already-allow-listed create-time caps and passes) |
| any `"type":"b"` device rule; any allow-device rule whose `major:minor` is outside Docker's default set (`1:3 1:5 1:7 1:8 1:9 5:0 5:1`); wildcards without a major | `--device /dev/vda1` (raw VM disk, r/w) and `--device /dev/mem`. Checked per-rule (field-order independent) so a specific `--device` rule cannot hide behind a privileged-wildcard pattern |
| namespace joins two ways: an explicit `path` (`container:` joins, legacy `=host`), and a **missing** `mount/network/uts/pid/ipc` entry — docker's `=host` modes omit the namespace instead of creating one. `cgroup`/`time` are deliberately not required (docker's default `cgroupns` is host on cgroup-v1 hosts) | `--pid=host` / `--uts=host` / `--network=host` (process list + `/proc/1/mountinfo` leak) |
| bind sources outside the allowed set — checked **twice** (as written in the spec, and as `readlink -f` resolves it in the daemon's mount namespace) and then **kernel-pinned** (see below) | **daemon tampering**: mounting the daemon's rootfs to overwrite the guard itself — the bypass that defeats any API-only policy; and **symlinked sources**: `ln -s / /workspace/link; docker run -v /workspace/link:/mnt` — the spec shows an innocent workspace path, the kernel resolves the symlink at mount time and delivers the daemon's entire rootfs, rw |
| the daemon plumbing files (`/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`) as bind **sources**, and per-container plumbing files that aren't docker's own shape (source under *this* container's id, destination exactly `/etc/<name>`) | docker bind-mounts those plumbing files **rw into every nested container**. Binding the bare `/etc/*` files (`docker run -v /etc/hosts:/h`) delivers the **daemon's own** `/etc/hosts` rw to a nested container — a persistent write that DNS-pins the daemon and every future container. Docker's own per-container plumbing (rw, unpinned) stays; grafts of a *foreign* container's plumbing, or at a non-canonical destination, refuse |
| any volume whose directory carries an **`opts.json`** — i.e. created with `docker volume create -o device=… -o type=…` or `--mount volume-opt=…` | **daemon-side mounts**: the local volume driver makes *dockerd itself* mount an arbitrary device or filesystem (`device=/dev/vda1`, `type=none,o=rbind,device=/`); the spec only ever shows a plausible `/var/lib/docker/volumes/<name>/_data` source, so no spec-level bind policing can see it. Blast radius: `type=none,device=/` exposes the *daemon's* root (session data, CA certs — its namespace, not the VM's); `device=/dev/vda…` mounts VM disks — the true escape path |

**Why the opts-volume refusal also kills dockerd.** The daemon mounts the
volume *before* the guard runs (the guard sees `config.json`, the mount
already exists). Refusing is not enough: docker's rollback then unmounts
the volume recursively, and an `rbind` of `/` has copied `/proc` (and
friends) into a peer group — the teardown unmount propagates onto the
daemon's own `/proc` and leaves a zombie that cannot start or exec
anything (reproduced: `open /proc/sys/kernel/cap_last_cap: no such file
or directory`, unrecoverable in place). So on detection the guard SIGKILLs
dockerd *first*: no rollback ever runs, the daemon container exits
cleanly, and `pia` recreates it on the next command. Self-destruct
attempts become a daemon restart, not a dead session. Recovery is
session-scoped and human-gated on purpose (no in-container supervisor:
a restart there would keep the evil mounts alive in the same namespace
and defer the zombie unmount): pia warns
on `exec`/`sh`/`monitor`/`ask`/`resume` when it finds a running agent
whose daemon is dead, naming `pia dindlog` and the two-step recovery;
the kill itself stays terminal. (Making the mount
impossible would need an API-layer filter/authz plugin — the daemon
directory cannot even be pre-created via `docker cp`, and Docker locks the
container mount tree against propagation changes from inside.)

**Bind whitelist** (`/usr/local/etc/pia-dind-guard.conf`, written at daemon
start by the image entrypoint from `$PIA_GUARD_WS`): plain `dind` → nothing
beyond Docker's own plumbing — a
**narrow** set: named-volume data dirs (`volumes/*/\_data`), buildkit
scratch, and the per-container `resolv.conf`/`hostname`/`hosts` files;
`dind-dev` → plus `/workspace`. A blanket `/var/lib/docker/*` allow would
admit every agent-writable daemon directory (`tmp/`) as a staging area, so
the set is kept narrow. Direct access to the nested daemon's
containerd state or socket would bypass dockerd *and* the guard, hence
the deny list.

**Kernel-side pinning — closing the TOCTOU race.** Checking the spec
string and even `readlink -f` are *two resolutions with a window between
them*: an atomic `ln`+`mv -T` loop can flip a workspace symlink between a
safe directory and `/` between the two — the guard samples "safe", the
kernel mounts `/`. String checks cannot close this; only the kernel's own
resolution can. So for every bind source under an agent-writable allowed
prefix the guard: (1) bind-mounts the source onto its own private mountpoint
under `/.pia-dind-guard/pins/`, (2) reads `/proc/self/mountinfo` to learn
which `(dev, root)` the **kernel** actually resolved, (3) refuses unless that
is the allowed prefix's own filesystem and a subpath of it, (4) rewrites the
spec's `source` to the pin mountpoint (via jq — exact string equality, no
sed escaping layer) — a mountpoint cannot be renamed out from under
(`EBUSY`), so runc's later bind mounts exactly what was verified. Three
invariants the mechanics depend on: pin mounts must be `--make-rprivate`
(they otherwise inherit the daemon's *shared* propagation and replicate,
including a raced daemon-root pin, into every sibling container); pins live
outside `/run` and `/var/lib` (a nested `-v /run:/host` recursive-binds
those, pins included); and release runs **first** in `die()` (stderr can
SIGPIPE once the shim is gone). Every guarded create also sweeps stale pins
from dead processes.

**A derived image, verified at runtime.** The guard and its jq parser ship
in `pia-dind:guard-v<N>`, built from `docker/pia-dind/` (`FROM
docker:29-dind@sha256:…`, digest-pinned; `docker history` shows every
addition — a 15-line diff over the audited upstream). The image entrypoint
writes the bind whitelist from `$PIA_GUARD_WS` (mode is decided by pia at
daemon create), swaps the guard in as `runc`, makes the policy files
immutable, and only then execs the upstream entrypoint — so **no nested
container can ever have existed that was not created through the guard**.
Policy versioning is the image tag: changing the guard changes the tag, so
the next `build-docker.sh` yields a new image; `pia` verifies every daemon
it reuses and recreates daemons that fail, on two independent grounds —
**content** (`/usr/local/bin/runc` still carries the expected marker, jq
present: catches a tampered writable layer, and the only real gate for a
user-supplied `PIA_DIND_IMAGE`) and **fingerprint** (the daemon was created
from the current image id: a rebuild changes the id even when the version
string does not, so the "forgot to bump `GUARD_VERSION`" footgun cannot
bless a stale daemon — the marker is provenance, not the decision).
`PIA_DIND_IMAGE` is pulled if absent but still content-verified — an image
without the current guard is refused and removed (fail-closed). One honest
trade: the policy source is readable in the image by anyone who can pull
it — it was never secret, and the design does not rely on its obscurity.

**Immutability.** The guard files, their source copy, the whitelist and jq
are `chattr +i`'d by the entrypoint (the flag cannot survive image export,
it must be set on the running container's own overlay upper). With the
daemon's filesystem writable at all, a writable *shim* is just as deadly as
a writable guard — patch it, restart the daemon, no guard bug needed.
Name-based pinning is not enough: docker 29 **embeds containerd inside
dockerd** (no standalone binary exists at entrypoint time), so after startup
`harden_dind_toolchain()` additionally pins whatever the running processes
actually executed (`readlink /proc/<pid>/exe`) and sweeps the usual
`/usr/local/bin` names. Immutable forces an image-level change instead,
which a nested workload cannot make. Clearing +i needs daemon root plus
`CAP_LINUX_IMMUTABLE`, which the policy makes unreachable.

**Observability.** A refusal now reaches the agent verbatim: the guard
writes the reason to the runtime log in **runc's own logrus format**
(`{"level":"error","msg":…}`) — that is the field containerd ≥ 2.x parses
and surfaces as the client-facing `OCI runtime create failed: pia-dind-guard:
REFUSED: <reason>`. The historic `{"log","args","err"}` shape is not read,
leaving only the opaque `runc did not terminate successfully`. Every refusal is also logged inside the daemon, with a
CONTEXT line recording whether the log channel existed — read it with:

```bash
pia dindlog <name>        # the agent's daemon; works even after a kill-switch exit
# equivalently:
docker exec pia-<name>-dind cat /var/log/pia-dind-guard.log
```

`docker exec` into a nested container is inspected too: "exec cannot exceed
create-time bounds" is **false** — `docker exec --privileged` injects every
capability and `runc exec -f` replaces the process config wholesale, so
both channels are refused when they try to exceed the allow-list. A normal
exec carries the container's already-policed create-time caps and passes.

Every known bypass is a permanent regression test:
`scripts/tests/guard-bypass-check.sh <daemon-container>` replays the full kit
(privilege, caps allow-list incl. BPF/PERFMON, seccomp strength, exec-time
privilege injection, devices, namespace joins, tamper binds, plumbing-file
grafts, symlinked binds, the flipping-symlink race, the tmp-seed bind,
exec false-positive, toolchain immutability, opts volumes) against a live
daemon and prints a scorecard. `scripts/tests/dind-escape-check.sh` runs the same chain from
*inside* the agent container — through the real attack surface.

**What the guard cannot cover:** kernel and dockerd/containerd/runc CVEs
(the daemon itself is privileged and its own API surface is not policed),
resource DoS, and whatever workspace you hand it. See §8.

---

## 6. `dind-dev`: when you need bind mounts

`docker build` streams its context, so plain `--docker` builds from
`/workspace` fine — but real dev stacks mount things at *run* time, and
those mounts resolve in the daemon:

```bash
docker compose up                       # ./nginx.conf, ./configs, ./init.sql
docker run -v $PWD:/app -w /app node:22 npm test   # live source, no rebuild
```

`--docker=dind-dev` mounts the `-m` workspace into the **daemon** at the same
path the agent sees (`/workspace` in both). A nested
`-v /workspace/app:/etc/app:ro` therefore resolves to the real project
directory. The bind is `rprivate`: mounts created inside nested containers
can never propagate back into the host mount namespace.

The invariant, asserted by the test suite: plain `dind` gives the daemon
**zero** host binds, `dind-dev` exactly **one** — the workspace. Costs,
exactly:

- Nested containers write there **as root** (no userns remapping yet, issue
  #9): leftovers are root-owned on the host.
- Anything the daemon runs can read it without asking — `.env`, git
  credentials — and the workspace is an **execution** surface on the host
  side later (`.git/hooks`, `core.hooksPath`, `postinstall`, `Makefile`).
- It **requires `-m`** (refused without it rather than silently degrading to
  plain dind); `pia ask` accepts it only for ephemeral sessions.
- Changing the workspace **recreates** the daemon (binds are frozen at
  creation; a stale host view is worse than a lost image cache).

---

## 7. What works / what to watch (inside the agent)

- **Works**: `docker build` (context is streamed), `pull`, `push`, `save`,
  `load`, `cp`, `run`, `docker compose up` — with named volumes under plain
  `--docker`, and with bind mounts under `--docker=dind-dev`.
- **Plain `--docker` bind mounts fail SILENTLY with an empty directory**:
  the daemon has no view of your files (security boundary, not a limitation
  to work around inside the daemon). Use named volumes, `docker cp`, or
  `--docker=dind-dev`.
- **Images live in the daemon's own storage**: no host cache reuse, and
  everything is discarded with the session (`pia rm` removes the daemon and
  its volumes). First `docker pull` per session costs bandwidth and disk.
- **Shared netns**: `localhost` inside the agent reaches containers the
  daemon runs (and vice versa) — useful for test stacks, and it means any
  localhost listener inside the agent is reachable from nested containers.
- **Observability**: daemon traffic is cleartext HTTP on 2375 inside the
  shared netns, so `pia monitor` / `pia urls` show it — unlike a raw
  socket, which hides everything.

---

## 8. Threat model

### 8.1 What `--docker` actually grants

Said plainly: **`--docker` gives the agent the power to run arbitrary
containers as root.** The guard refuses the ones with widening powers
(`--privileged`, `--pid=host`, raw devices), so that root lives in the
throwaway daemon's namespaces and ordinary nested containers behave like
containers anywhere else. Root *inside the session* is accepted behaviour —
the question is only how far it reaches, and the answer depends on the
runtime pia auto-detects:

| Host runtime | Daemon | Reach of nested root | Boundary |
|---|---|---|---|
| **sysbox / gVisor** | unprivileged, Docker default caps + seccomp, inherited downward and unwidenable | the daemon's own namespaces only; host filesystem, socket, processes, other sessions unreachable | **real boundary** |
| **plain runc (incl. Docker Desktop)** | `--privileged` + guard | walk-in escapes refused by the guard; remaining routes are kernel / dockerd / containerd / runc CVEs, plus DoS and the workspace | hardening; hostile input belongs in no-`--docker` |

Check what your host actually enforces:

```bash
docker info --format '{{.SecurityOptions}} {{.Runtimes}}'
docker inspect pia-<name>-dind --format '{{.HostConfig.Runtime}} {{.HostConfig.Privileged}} {{json .HostConfig.Binds}}'
docker exec pia-<name>-dind grep -E 'CapBnd|^Seccomp' /proc/1/status   # Seccomp: 2 = filter mode
pia dindlog <name>                                                      # guard refusals
```

### 8.2 Docker Desktop specifics (verified on macOS/arm64, linuxkit kernel)

These facts drove the design; they were confirmed end-to-end on a real
install, from a client holding **nothing but the daemon's TCP API**:

- The VM data disk (`/dev/vdb`) is mountable read-only from a privileged
  container: the full Docker Desktop VM filesystem, every container and
  volume of the installation.
- The VM's virtiofs share tags are readable under `/sys/fs/virtiofs/*/tag`
  and mountable with `CAP_SYS_ADMIN` alone: the macOS file-sharing set
  (default: `/Users`, `/tmp`, `/Volumes`, `/opt`) — **read and write**.
  The escape therefore never reaches "macOS root" (no keychain, no host
  processes), but it does reach every file in the shared folders, which for
  most users includes the entire home directory.
- There is neither sysbox nor gVisor for Docker Desktop, so no strong dind
  boundary exists there; the guard raises hostile-input requirements from
  "nothing" to "a privilege-escalation exploit".

### 8.3 Known residual risks

- **Image-baked device nodes are a guard blind spot.** `docker import`/`docker commit` can put `/dev/vda1` (254:1) or
  `/dev/mem` (1:1) into an image’s rootfs; the container spec then carries
  no device rule, so the guard has nothing to refuse and the container
  starts. It is harmless because the **cgroup-v2 eBPF device filter** denies
  `open()` on every non-default device one layer down (verified EPERM in
  both the nested and the agent container) — defense-in-depth, not the
  guard. Closing it at the guard means scanning committed/imported rootfs
  content, which the spec-only design cannot see; documented follow-up.
- **`--security-opt apparmor=unconfined` is invisible on a non-AppArmor
  host.** On this Alpine daemon (no AppArmor) moby
  writes **no** `apparmorProfile` field, so the guard’s `== "unconfined"`
  check sees `""` and correctly allows it — there is no LSM to disable, so
  nothing is granted. On an AppArmor host moby *does* write the profile, and
  a caller could pass a permissive named profile the guard cannot read the
  contents of. Checking Docker’s own `HostConfig.SecurityOpt` is not
  possible at the runc layer (the guard sees the OCI spec, not the
  HostConfig); an AppArmor-aware host would need the check pushed up to the
  CLI. Open, host-dependent.
- **Exploit class on plain runc.** The daemon is privileged on a shared
  kernel; a kernel or daemon-component CVE still escapes. The guard covers
  policy, not the daemon's own API surface.
- **The daemon is root *inside the session*, and the agent controls it.**
  Anything in the agent's netns drives the daemon; ordinary nested
  containers are fully agent-owned. Blast radius ends where the daemon
  container ends: no host filesystem, no host socket, no host images.
- **No resource limits on the daemon yet.** A greedy build can exhaust host
  RAM, PIDs and **disk** (image storage is an anonymous volume on your real
  disk, reclaimed only by `pia rm`/`pia clean` with `-v`). Watch `df` on
  long-lived sessions.
- **`--docker=dind-dev` widens one directory to the whole session** — and
  the workspace is a two-way door (secrets in, hook/script execution out on
  the host later). Treat it as shared state with the agent, not a sandbox.
- **`/proc/self/mountinfo` in the pia container is unmasked:** on Docker Desktop it leaks the TRUE host path of the container's own
  binds (`/Users/<user>/…`) plus the username. Docker offers no CLI mask
  for it; keep secrets out of paths you bind, or run hostile workloads
  without `-m`.
- **The VM share scope is your setting.** Docker Desktop's file-sharing
  default exposes the whole `/Users` tree to anything that reaches the VM
  (a daemon-root-with-CVE scenario); restricting the share list shrinks
  every VM-side breach to the directories you actually need.
- **Pi session logs live on the VM disk** (transient containers, image
  layers): anyone with VM-disk read access can read agent conversations
  verbatim. Same mitigation as any disk-at-rest concern.
- **Nested cgroups sit under the privileged daemon's cgroup root.** The
  self-move into the daemon's allow-all cgroup that defeats the device
  filter requires filesystem reach into the daemon — reach the kernel-pinned
  binds refuse; on sysbox/gVisor the daemon is not privileged so the route
  does not exist. A dedicated deny-all device subtree would close it
  structurally — open follow-up. User-namespace remapping is the follow-up
  that strengthens this mode.
- **`--docker=socket` is host root by design.** The banner is a speed bump.
  Authz plugins on the host daemon are hardening only (they fail open).
- The **agent container's own** mounts (workspace, `--ssh` agent) and the
  forwarded OpenRouter key are not protected by any daemon mode: mode choice
  bounds what *build workloads* can reach, not what the agent itself can
  read, modify, or sign.

---

## 9. Configuration reference

| Knob | Where | Default | Effect |
|---|---|---|---|
| `PIA_DIND_IMAGE` | env | (unset → built `pia-dind:guard-v<N>`) | daemon image; pulled if absent, verification still applies |
| `DOCKER_SOCKET` | env | `/var/run/docker.sock` | socket used by `--docker=socket` |
| `DIND_WS_TARGET` | `pia.sh` constant | `/workspace` | where dind-dev exposes the workspace inside the daemon |
| `PIA_DIND_GUARD_FILE` | env | (unset) | override the guard-script lookup (tests, power users) |
| `PIA_GUARD_WS` | daemon container env | (empty) | bind whitelist pia passes to the image entrypoint (dind-dev: `/workspace`) |
| `docker/pia-dind/` | repo (built by `build-docker.sh`) | marker `GUARD_VERSION=1` | daemon image build folder; guard version read from `guard.sh` line 2, daemons below it are recreated |
| `/usr/local/etc/pia-dind-guard.conf` | inside daemon | (written at daemon start) | bind-source whitelist enforced by the guard |
| `/var/log/pia-dind-guard.log` | inside daemon | — | guard refusals |

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Nested `docker run` dies with `unable to join session keyring` | Host seccomp blocks `keyctl` and the daemon is not privileged — pre-#8 daemon or a custom unprivileged `PIA_DIND_IMAGE`. Recreate: `pia restart NAME --docker` |
| Nested containers on bridge networks fail with `disable IPv6` errors | Daemon is unprivileged on a plain-runc host (read-only `/proc/sys`). Same fix as above |
| `REFUSED: …` from docker run, reason missing in CLI output | Guard refusal (CLI swallows runtime stderr). Read `/var/log/pia-dind-guard.log` in the daemon |
| `docker run -v …` mounts an empty directory | Plain `--docker`: binds resolve in the daemon. Use named volumes or `--docker=dind-dev` |
| `--docker=dind-dev needs a workspace: pass -m` | By design — dind-dev without `-m` would silently degrade to plain dind |
| Daemon "did not become ready" / "API never answered" | `docker logs pia-<name>-dind`; then `pia rm NAME` to recreate both halves |
| Files left in the workspace are root-owned | Nested containers write as root (no userns remap). `sudo chown -R` or keep build output out of the bind |
| `pia run NAME --docker` warns "created with a different --docker mode" | `--docker` is a creation-time option; the existing container keeps its baked-in mode. `pia restart NAME --docker=…` to change it |
| Session's docker **and** network die mid-session; daemon shows `exited` | Guard kill switch (daemon-side mount refusal) — by design terminal for the session. `pia dindlog NAME` shows why; recover BOTH halves in order: `docker start pia-NAME-dind && docker restart pia-NAME` (one-command `pia revive` planned) |

---

## 11. Related issues

- **#8 — nested-container guard**: implemented (this document, §5).
- **#9 — user-namespace remapping** for the daemon: planned; would make
  nested root *not* be real root (root-owned workspace files, weaker DAC
  reach).
- **`--docker=vm` tier** — daemon in its own kernel/VM: planned v2; the only
  tier that survives genuinely hostile input on Docker Desktop.
