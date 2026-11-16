#!/bin/sh
# dind-escape-check.sh — run INSIDE a pia agent container started with
# --docker (or --docker-dev) and verify the escape chain is closed
# from the agent's own seat: nested docker over DOCKER_HOST, no docker
# socket, default caps.
#
# Usage:  sh dind-escape-check.sh            (--docker-dev: full checks)
#         DOCKER_HOST + /workspace are taken as-is from the container.
# Exit 0 = every vector closed; non-zero = a vector is open (see FAIL lines).
set -u
IMAGE="${ESC_TEST_IMAGE:-alpine:3.22}"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# refused <desc> <args...> — nested docker run must FAIL
refused() {
    desc="$1"; shift
    if docker run --rm "$@" > /dev/null 2>&1; then bad "$desc — MOUNTED/RAN"; else ok "$desc"; fi
}

echo "== agent-side escape verification"

# pre-flight: the agent's nested docker must work at all
if ! docker run --rm "$IMAGE" echo ok > /dev/null 2>&1; then
    echo "ABORT — nested docker run does not work from this container (is --docker active? can '$IMAGE' be pulled?)"
    exit 2
fi
ok "ordinary nested run works"

if [ ! -d /workspace ]; then
    echo "SKIP  symlink checks (no /workspace — plain --docker, no daemon-side writes possible)"
else
    # Symlink bind sources — the workspace is bind-mounted into the agent
    # AND into the daemon, so the agent can plant the symlink itself.
    ln -sfn / /workspace/.esc-sym
    mkdir -p /workspace/.escdir && ln -sfn /etc /workspace/.escdir/etc
    refused "symlink bind to / (TOCTOU)"       -v /workspace/.esc-sym:/mnt "$IMAGE" ls /mnt
    refused "symlinked intermediate (TOCTOU)"  -v /workspace/.escdir/etc/passwd:/x "$IMAGE" cat /x
    rm -f /workspace/.esc-sym; rm -rf /workspace/.escdir

    # The daemon's cgroupfs must not be reachable through any source the
    # agent can plant.
    ln -sfn /sys /workspace/.esc-sys
    refused "cgroupfs via symlink chain" -v /workspace/.esc-sys:/c "$IMAGE" ls /c
    rm -f /workspace/.esc-sys
fi

# exec must not be a false-positive refusal
docker rm -f esc-exec > /dev/null 2>&1
docker run -d --name esc-exec "$IMAGE" sleep 20 > /dev/null 2>&1
if docker exec esc-exec echo ok > /dev/null 2>&1; then ok "nested docker exec works"; else bad "nested docker exec REFUSED"; fi
docker rm -f esc-exec > /dev/null 2>&1

# classic privilege vectors through the agent's own API access
refused "--privileged nested"        --privileged "$IMAGE" true
refused "daemon root bind (tamper)"  -v /:/host "$IMAGE" true
refused "--device /dev/vda1"         --device /dev/vda1 "$IMAGE" true
refused "--pid=host"                 --pid=host "$IMAGE" true

# opts volumes (KILLS the daemon — run last; agent-side, the daemon dying is
# the PASS condition: refusal + clean self-termination)
if docker volume create esc-evil -o type=none -o o=rbind -o device=/ > /dev/null 2>&1; then
    if docker run --rm -v esc-evil:/y "$IMAGE" ls /y > /dev/null 2>&1; then
        bad "opts volume rbind of / — MOUNTED"
    else
        ok "opts volume rbind of / — refused"
    fi
    sleep 2
    echo "NOTE  the daemon should now be stopped (guard kill switch); recreate with 'pia restart'."
else
    echo "SKIP  opts volume checks (volume create failed)"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
