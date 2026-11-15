#!/bin/sh
# guard-bypass-check.sh — red-team regression kit for pia-dind-guard.
#
# Runs every known bypass against a RUNNING daemon container and prints a
# PASS/FAIL scorecard. A bypass is
# closed when the nested 'docker run' FAILS (guard refusal) — so the kit is
# safe: no refused container ever starts.
#
# Usage:  sh guard-bypass-check.sh <daemon-container>
# e.g.:   sh guard-bypass-check.sh pia-myagent-dind
#
# NOTE: the opts-volume bypass triggers the guard's dockerd kill
# switch BY DESIGN — run that check LAST; after it the daemon has exited
# (cleanly, recoverable with 'pia' — never zombified) and further checks
# cannot run.
set -u
DAEMON="${1:?usage: guard-bypass-check.sh <daemon-container>}"
IMAGE="${GUARD_TEST_IMAGE:-alpine:3.22}"
PASS=0
FAIL=0

# refused <description> <docker-args...>
refused() {
    desc="$1"
    shift
    if docker exec "$DAEMON" docker run --rm "$@" > /dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "FAIL  $desc"
    else
        PASS=$((PASS + 1))
        echo "PASS  $desc"
    fi
}

echo "== pia-dind-guard bypass kit — daemon: $DAEMON"

# pre-flight: ordinary runs must work (also warms the image cache)
if ! docker exec "$DAEMON" docker run --rm "$IMAGE" echo ok > /dev/null 2>&1; then
    echo "ABORT — ordinary nested run failed (daemon down, no network for '$IMAGE', or guard too strict)"
    exit 2
fi
echo "PASS  ordinary nested run works"

# --- privilege, caps, devices, host namespaces, daemon binds ----------
refused "--privileged"                        --privileged "$IMAGE" true
refused "--cap-add CAP_SYS_ADMIN"             --cap-add CAP_SYS_ADMIN "$IMAGE" true
refused "--device /dev/vda1 (raw disk)"       --device /dev/vda1 "$IMAGE" true
refused "--device /dev/mem"                   --device /dev/mem "$IMAGE" true
refused "--pid=host"                          --pid=host "$IMAGE" true
refused "--uts=host"                          --uts=host "$IMAGE" true
refused "--network=host"                      --network=host "$IMAGE" true
refused "--ipc=host"                          --ipc=host "$IMAGE" true
refused "--pid=container:1"                   --pid=container:1 "$IMAGE" true
refused "guard tamper (bind of daemon root)"  -v /:/host "$IMAGE" true
refused "daemon-internal containerd bind"     -v /var/lib/docker/containerd:/x "$IMAGE" true

# --- symlinked bind sources (TOCTOU) ------------------------------------
# The literal source string is policed, but the kernel resolves symlink
# components at mount time — 'ln -s / <ws>/link' can mount the daemon's
# whole rootfs rw. Needs a workspace (dind-dev): only there is a source
# allowed LITERALLY, which is what makes the resolution check meaningful.
if docker exec "$DAEMON" test -d /workspace; then
    docker exec "$DAEMON" sh -c 'ln -sfn / /workspace/.kit-sym; mkdir -p /workspace/.kitdir && ln -sfn /etc /workspace/.kitdir/etc'
    refused "symlink bind to /"           -v /workspace/.kit-sym:/mnt "$IMAGE" ls /mnt
    refused "symlinked intermediate"      -v /workspace/.kitdir/etc/passwd:/x "$IMAGE" cat /x
    docker exec "$DAEMON" sh -c 'rm -f /workspace/.kit-sym; rm -rf /workspace/.kitdir'
else
    echo "SKIP  symlink bind checks (no /workspace in daemon — plain dind)"
fi

# exec must WORK: an early version refused 'runc exec' because docker passes
# no --bundle. A refusal here is a guard FALSE POSITIVE.
docker exec "$DAEMON" docker run -d --name guard-kit-exec "$IMAGE" sleep 20 > /dev/null 2>&1
if docker exec "$DAEMON" docker exec guard-kit-exec echo ok > /dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "PASS  nested docker exec allowed (no exec false-positive)"
else
    FAIL=$((FAIL + 1)); echo "FAIL  nested docker exec REFUSED (guard false positive)"
fi
docker exec "$DAEMON" docker rm -f guard-kit-exec > /dev/null 2>&1

# The guard binary must be immutable (chattr +i) — a writable guard is a
# patched guard.
if docker exec "$DAEMON" sh -c 'echo x >> /usr/local/bin/runc' 2>/dev/null; then
    FAIL=$((FAIL + 1)); echo "FAIL  guard binary is WRITABLE (tamper)"
else
    PASS=$((PASS + 1)); echo "PASS  guard binary immutable (tamper-proof)"
fi

# The whole daemon toolchain must be immutable — a writable containerd-shim
# means patch-and-restart, no guard bug needed. The tamper probe APPENDS, so
# a successful tamper is RESTORED from a backup copy (a plain 'rm -f' cleanup
# would delete the daemon's binaries and break every later probe).
for f in dockerd containerd containerd-shim-runc-v2 docker-init docker-proxy docker; do
    if ! docker exec "$DAEMON" sh -c "test -e /usr/local/bin/$f" 2>/dev/null; then
        # docker 29 embeds containerd in dockerd — no standalone binary.
        # The running exe is what must be immutable (checked via dockerd).
        PASS=$((PASS + 1)); echo "PASS  /usr/local/bin/$f absent (embedded/none)"
    elif docker exec "$DAEMON" sh -c "cp /usr/local/bin/$f /tmp/kit-bak && echo x >> /usr/local/bin/$f" 2>/dev/null; then
        FAIL=$((FAIL + 1)); echo "FAIL  /usr/local/bin/$f is WRITABLE (toolchain patch)"
        docker exec "$DAEMON" sh -c "cat /tmp/kit-bak > /usr/local/bin/$f; rm -f /tmp/kit-bak" 2>/dev/null
    else
        PASS=$((PASS + 1)); echo "PASS  /usr/local/bin/$f immutable"
    fi
done

# The tmp/ seed bind (writable dir under the daemon's filesystem) must be
# refused by the narrowed allow-list.
refused "daemon tmp seed (race seed)"        -v /var/lib/docker/tmp:/x "$IMAGE" true

# Flipping-symlink race. An atomic ln+mv loop flips
# the bind source between '/workspace/.kit-race-safe' and '/' between the
# guard's resolution and the kernel's. With kernel-side pinning every flip
# is caught; zero HITs is a PASS.
if docker exec "$DAEMON" sh -c 'test -d /workspace' 2>/dev/null; then
    RACE=/workspace/.kit-race
    docker exec "$DAEMON" sh -c "mkdir -p /workspace/.kit-race-safe; ln -sfn /workspace/.kit-race-safe $RACE"
    docker exec -d "$DAEMON" sh -c "while :; do ln -sfn /workspace/.kit-race-safe $RACE.t; mv -Tf $RACE.t $RACE 2>/dev/null; ln -sfn / $RACE.t; mv -Tf $RACE.t $RACE 2>/dev/null; done" >/dev/null 2>&1
    HITS=0
    for i in 1 2 3 4 5 6 7 8; do
        out=$(docker exec "$DAEMON" docker run --rm -v $RACE:/host:ro "$IMAGE" sh -c '[ -d /host/usr ] && echo HIT || echo safe' 2>/dev/null | tail -1)
        [ "$out" = "HIT" ] && HITS=$((HITS + 1))
    done
    docker exec "$DAEMON" pkill -f 'while :' 2>/dev/null
    docker exec "$DAEMON" pkill -f 'mv -Tf' 2>/dev/null
    docker exec "$DAEMON" rm -rf "$RACE" "$RACE.t" /workspace/.kit-race-safe 2>/dev/null
    if [ "$HITS" -eq 0 ]; then
        PASS=$((PASS + 1)); echo "PASS  flipping-symlink race: 0/8 escapes (kernel-side pin)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  flipping-symlink race: $HITS/8 ESCAPED"
    fi
else
    echo "SKIP  TOCTOU race (no /workspace in daemon — plain dind)"
fi

# --- caps allow-list, seccomp strength, exec privilege, plumbing --------
# A caps DENY-list misses BPF/PERFMON (kernel-memory read primitive) and many
# more; the policy is an ALLOW-list. Every non-default cap must refuse.
refused "--cap-add BPF (kernel-read)"        --cap-add BPF "$IMAGE" true
refused "--cap-add PERFMON"                     --cap-add PERFMON "$IMAGE" true
refused "--cap-add CHECKPOINT_RESTORE"            --cap-add CHECKPOINT_RESTORE "$IMAGE" true
refused "--cap-add LINUX_IMMUTABLE (chattr risk)" --cap-add LINUX_IMMUTABLE "$IMAGE" true
refused "--cap-add ALL (allow-list defeats it)"   --cap-add ALL "$IMAGE" true
# --security-opt seccomp=unconfined omits the seccomp section; refuse it
# (and any non-deny-by-default profile).
refused "--security-opt seccomp=unconfined"     --security-opt seccomp=unconfined "$IMAGE" true
# The allow-list must still PERMIT Docker's default caps (else every normal
# container breaks — a false-positive guard is as useless as an open one).
if docker exec "$DAEMON" docker run --rm --cap-drop ALL \
        --cap-add CHOWN --cap-add SETUID --cap-add NET_RAW \
        "$IMAGE" true > /dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "PASS  default caps (CHOWN/SETUID/NET_RAW) still allowed"
else
    FAIL=$((FAIL + 1)); echo "FAIL  allow-list too strict — legitimate default caps refused"
    if ! docker exec "$DAEMON" docker run --rm "$IMAGE" true > /dev/null 2>&1; then
        echo "      NOTE: ordinary nested run ALSO fails — daemon is broken; later PASSes may be false"
    fi
fi
# /etc/hosts, /etc/resolv.conf, /etc/hostname are not bindable sources (a
# nested container could rewrite the DAEMON's /etc/hosts through one).
refused "-v /etc/hosts (daemon plumbing)"         -v /etc/hosts:/h "$IMAGE" true
refused "-v /etc/resolv.conf"                     -v /etc/resolv.conf:/h "$IMAGE" true
# Cross-container graft: another container's hosts file at a non-canonical
# destination. Needs a live container to graft FROM.
GRAFT_SRC="$(docker exec "$DAEMON" docker run --rm -d "$IMAGE" sleep 30 2>/dev/null)"
if [ -n "$GRAFT_SRC" ]; then
    GRAFT_ID="$GRAFT_SRC"
    refused "foreign-container hosts graft"        -v "/var/lib/docker/containers/$GRAFT_ID/hosts:/x" "$IMAGE" true
    docker exec "$DAEMON" docker rm -f "$GRAFT_ID" > /dev/null 2>&1
else
    echo "SKIP  foreign-container hosts graft (no live container to graft)"
fi
# 'docker exec --privileged' injects every cap at exec time; the guard
# checks the exec argv and the '-f' process config. Needs a running container
# and an exec, so it is checked separately from the 'refused' (run) helper.
EXEC_C="$(docker exec "$DAEMON" docker run --rm -d "$IMAGE" sleep 30 2>/dev/null)"
if [ -n "$EXEC_C" ]; then
    if docker exec "$DAEMON" docker exec --privileged "$EXEC_C" true > /dev/null 2>&1; then
        FAIL=$((FAIL + 1)); echo "FAIL  docker exec --privileged was ALLOWED"
    else
        PASS=$((PASS + 1)); echo "PASS  docker exec --privileged refused"
    fi
    # A normal exec must still work (no false-positive).
    if docker exec "$DAEMON" docker exec "$EXEC_C" true > /dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "PASS  normal docker exec still allowed"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  normal docker exec broke (false-positive)"
    fi
    docker exec "$DAEMON" docker rm -f "$EXEC_C" > /dev/null 2>&1
else
    echo "SKIP  exec --privileged checks (no live container)"
fi

# PROPERTY: 'docker cp' must never resolve symlink sources SERVER-SIDE.
# The archive carries the LINK, never the target's bytes (verified against
# moby 29: file and dir links both come out as link members). If a future
# moby starts resolving sources server-side, a hostile IMAGE gets a read
# channel for daemon files (link → daemon-only path, read back through any
# API-driven cp) — the canary link below points at the guard's own source.
# (Reported once as an "escape into the agent's filesystem": disproven on
# repro — extracting the archive and READING the links resolves them against
# the extractor's own root, plain tar semantics; reader-side, not daemon-side.)
CP_VOL=guard-kit-cp
docker exec "$DAEMON" docker rm -f guard-kit-cp > /dev/null 2>&1
docker exec "$DAEMON" docker volume rm "$CP_VOL" > /dev/null 2>&1
if docker exec "$DAEMON" docker volume create "$CP_VOL" > /dev/null 2>&1 \
   && docker exec "$DAEMON" docker run -d --name guard-kit-cp -v "$CP_VOL:/v" "$IMAGE" sleep 30 > /dev/null 2>&1 \
   && docker exec "$DAEMON" docker exec guard-kit-cp ln -sf /usr/local/lib/pia-dind/guard.sh /v/cplink; then
    CP_BYTES="$(docker exec "$DAEMON" sh -c 'docker cp guard-kit-cp:/v/cplink - 2>/dev/null | tar -xOf - 2>/dev/null' | grep -c 'pia-dind-guard' 2>/dev/null || true)"
    CP_LINK="$(docker exec "$DAEMON" sh -c 'docker cp guard-kit-cp:/v/cplink - 2>/dev/null | tar -tf - 2>/dev/null' | grep -c 'cplink' 2>/dev/null || true)"
    if [ "${CP_BYTES:-1}" = "0" ] && [ "${CP_LINK:-0}" != "0" ]; then
        PASS=$((PASS + 1)); echo "PASS  cp read carries the link, never the target bytes"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  cp read leaked target bytes server-side or lost the link (moby behavior change: bytes=$CP_BYTES link=$CP_LINK)"
    fi
else
    echo "SKIP  cp read symlink property (could not stage the probe)"
fi
docker exec "$DAEMON" docker rm -f guard-kit-cp > /dev/null 2>&1
docker exec "$DAEMON" docker volume rm "$CP_VOL" > /dev/null 2>&1

# --- opts volumes: KILLS THE DAEMON — always last ------------------------
# The local volume driver mounts options are executed by dockerd itself;
# the spec only shows a plausible volumes/<name>/_data source. Detection
# is opts.json; the refusal also kills dockerd so docker's rollback never
# runs the recursive unmount that would zombie the daemon.
EVIL="guard-kit-evil"
docker exec "$DAEMON" docker volume rm "$EVIL" > /dev/null 2>&1
if docker exec "$DAEMON" docker volume create "$EVIL" -o type=none -o o=rbind -o device=/ > /dev/null 2>&1; then
    if docker exec "$DAEMON" docker run --rm -v "$EVIL:/y" "$IMAGE" ls /y > /dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "FAIL  opts-volume rbind of / — MOUNTED"
    else
        PASS=$((PASS + 1))
        echo "PASS  opts-volume rbind of / — refused"
    fi
    sleep 2
    state=$(docker inspect -f '{{.State.Status}}' "$DAEMON" 2>/dev/null)
    if [ "$state" = "exited" ]; then
        PASS=$((PASS + 1))
        echo "PASS  kill switch ended the daemon cleanly (exited, recreatable)"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL  kill switch did not end the daemon (state: $state — zombified?)"
    fi
    docker exec "$DAEMON" docker volume rm "$EVIL" > /dev/null 2>&1
else
    echo "SKIP  opts-volume checks (volume create failed)"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
