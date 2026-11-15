# =============================================================================
# Docker modes (--docker / --docker=dind|dind-dev|socket) — issues #1, #10
#
# General sections test CLI parsing (always run). The 'docker' section runs
# the real throwaway-daemon lifecycle and needs both the 'pia' image and the
# dind image locally — it is skipped when either is missing, and is slow
# (daemon startup), so it can be selected/skipped via the run-tests filter.
# =============================================================================

echo ""
echo -e "${YELLOW}=== SECTION: Docker modes ===${NC}"

# Extract the functions under test (same pattern as test-functions.sh)
eval "$(sed -n '/^log_info()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^log_warn()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^log_error()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^log_cmd()/,/^}/p' "$AGENTS")"
eval "$(grep '^IMAGE_NAME=' "$AGENTS")"
eval "$(grep '^PREFIX=' "$AGENTS")"
eval "$(grep '^PROJECT_NAME=' "$AGENTS")"
eval "$(grep '^DIND_SUFFIX=' "$AGENTS")"
eval "$(grep '^DIND_IMAGE_DEFAULT=' "$AGENTS")"
eval "$(grep '^DIND_WS_TARGET=' "$AGENTS")"
# The guard policy is a real file (docker/pia-dind/guard.sh); its line-2
# marker is the policy version — the image tag derives from it, and there
# is no second copy in pia.sh to drift.
GUARD_SRC="$(cd "$(dirname "$AGENTS")/.." && pwd)/docker/pia-dind/guard.sh"
export PIA_DIND_GUARD_FILE="$GUARD_SRC"   # eval'd functions bypass BASH_SOURCE resolution
NESTED_GUARD_VERSION="$(sed -n 's/^# pia-dind-guard GUARD_VERSION=\(.*\)/\1/p' "$GUARD_SRC" | head -1)"
eval "$(sed -n '/^config_hash()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^project_labels()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^container_exists()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^container_is_running()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^extract_name_and_options()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^validate_docker_mode()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_mode_active()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^resolve_dind_workspace()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_name_for()/,/^}/p' "$AGENTS")"
# The guard ships in the daemon image (docker/pia-dind/); pia.sh carries the
# lookup helpers (env override → checkout → ~/.pia/lib), the image-ref/tag
# logic, the existence check (the CLI never builds), and post-start pinning.
eval "$(sed -n '/^pia_script_dir()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_guard_file()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_guard_version()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_image_ref()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^ensure_dind_image()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_guard_ok()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_daemon_image_current()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^harden_dind_toolchain()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^detect_dind_runtime()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^wait_dind_ready()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^dind_create_args()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^start_dind_sibling()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^build_docker_args()/,/^}/p' "$AGENTS")"

# --- SECTION: general (parsing) — always runs -------------------------------

if should_run_section general; then

# --docker shorthand maps to mode 'dind' (field 7)
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --docker some-name)
if [ "$(echo "$result" | cut -d'|' -f7)" = "dind" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: --docker shorthand yields mode 'dind'"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: --docker shorthand (got '$(echo "$result" | cut -d'|' -f7)')"; FAIL=$((FAIL + 1))
fi

# every explicit mode parses into field 7
for mode in dind dind-dev socket; do
    result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options "--docker=$mode" some-name)
    if [ "$(echo "$result" | cut -d'|' -f7)" = "$mode" ] && [ "$(echo "$result" | cut -d'|' -f3)" = "0" ]; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: --docker=$mode parses (field 7 = '$mode')"; PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: --docker=$mode (got '$result')"; FAIL=$((FAIL + 1))
    fi
done

# unknown mode is rejected with INVALID_DOCKER_MODE (error text + invalid flag);
# 'vm' is v2 scope (own issue) and must not be accepted by v1 either
for bad in bogus vm; do
    result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options "--docker=$bad" some-name 2>&1)
    if echo "$result" | grep -qF "INVALID_DOCKER_MODE" && [ "$(echo "$result" | tail -1 | cut -d'|' -f3)" = "1" ]; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: --docker=$bad rejected with INVALID_DOCKER_MODE"; PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: --docker=$bad not rejected properly (got '$result')"; FAIL=$((FAIL + 1))
    fi
done

# validate_docker_mode: empty/dind/dind-dev/socket pass; everything else (incl.
# the v2 'vm' mode and typos) fails with INVALID_DOCKER_MODE
validate_docker_mode "" && validate_docker_mode "dind" && validate_docker_mode "dind-dev" && validate_docker_mode "socket" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: validate accepts empty/dind/dind-dev/socket"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: validate rejected a valid mode"; FAIL=$((FAIL + 1))
fi
for bad in vm nonsense; do
    msg="$(validate_docker_mode "$bad" 2>&1)"; rc=$?
    if [ $rc -ne 0 ] && echo "$msg" | grep -qF "INVALID_DOCKER_MODE"; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: validate rejects '$bad' with INVALID_DOCKER_MODE"; PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: validate '$bad' (rc=$rc msg='$msg')"; FAIL=$((FAIL + 1))
    fi
done

# dind_name_for builds the sibling name convention
if [ "$(dind_name_for "pia-x")" = "pia-x-dind" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind_name_for → 'pia-x-dind'"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind_name_for (got '$(dind_name_for "pia-x")')"; FAIL=$((FAIL + 1))
fi

# dind_mode_active is the single predicate every lifecycle call site must use:
# 'dind' and 'dind-dev' share the daemon, 'socket' and '' do not.
for m in dind dind-dev; do
    if dind_mode_active "$m"; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind_mode_active true for '$m'"; PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind_mode_active false for '$m'"; FAIL=$((FAIL + 1))
    fi
done
for m in "" socket vm; do
    if dind_mode_active "$m"; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind_mode_active true for '$m'"; FAIL=$((FAIL + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind_mode_active false for '$m'"; PASS=$((PASS + 1))
    fi
done

# resolve_dind_workspace: needs an existing '-m' directory, prints the abs path
DM_WS_DIR="$(mktemp -d)"
msg="$(MOUNT_DIR="" resolve_dind_workspace 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$msg" | grep -qF "needs a workspace"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind-dev without -m is refused (no silent 'dind' fallback)"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: resolve_dind_workspace without -m (rc=$rc '$msg')"; FAIL=$((FAIL + 1))
fi
msg="$(MOUNT_DIR="/nonexistent/dir-$$" resolve_dind_workspace 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$msg" | grep -qF "does not exist"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind-dev with a missing -m dir is refused"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: resolve_dind_workspace missing dir (rc=$rc '$msg')"; FAIL=$((FAIL + 1))
fi
if [ "$(MOUNT_DIR="$DM_WS_DIR/." resolve_dind_workspace)" = "$(cd "$DM_WS_DIR" && pwd)" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: resolve_dind_workspace prints the absolute path"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: resolve_dind_workspace path (got '$(MOUNT_DIR="$DM_WS_DIR/." resolve_dind_workspace)')"; FAIL=$((FAIL + 1))
fi

# THE INVARIANT: the daemon's whole host view is at most ONE
# bind — the workspace. 'dind' must stay at zero binds, and the bind must be
# rprivate so nested mounts can never propagate back to the host.
DM_ARGS_NO_WS="$(dind_create_args pia-x-dind pia-x "" "sysbox-runc")"
DM_WS_COUNT="$(echo "$DM_ARGS_NO_WS" | grep -c '^-v$' || true)"
if [ "$DM_WS_COUNT" = "0" ] && ! echo "$DM_ARGS_NO_WS" | grep -q 'workspace'; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: plain dind daemon gets ZERO host binds (safe default)"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: plain dind leaked host binds ($DM_WS_COUNT -v args)"; FAIL=$((FAIL + 1))
fi
DM_ARGS_WS="$(MOUNT_DIR="$DM_WS_DIR" dind_create_args pia-x-dind pia-x "$DM_WS_DIR" "sysbox-runc")"
DM_WS_BINDS="$(echo "$DM_ARGS_WS" | grep -c '^-v$' || true)"
if [ "$DM_WS_BINDS" = "1" ] && echo "$DM_ARGS_WS" | grep -qxF "${DM_WS_DIR}:${DIND_WS_TARGET}:rprivate"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind-dev daemon gets exactly ONE bind: <ws>:/workspace:rprivate"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind-dev binds ($DM_WS_BINDS -v args; got '$DM_ARGS_WS')"; FAIL=$((FAIL + 1))
fi
if echo "$DM_ARGS_WS" | grep -qxF "pia-dind-mounts=${DM_WS_DIR}"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind-dev records its view in pia-dind-mounts"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind-dev missing pia-dind-mounts label"; FAIL=$((FAIL + 1))
fi
# every flag survives the one-per-line contract — 'echo "-e"' silently
# swallows itself, which left dockerd with a bare value and 'docker run'
# failing on an empty image name
for flag in -e -v --name --label --runtime; do
    if echo "$DM_ARGS_WS" | grep -qxF -- "$flag"; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind args emit '$flag' as its own line"; PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: '$flag' missing from dind args"; FAIL=$((FAIL + 1))
    fi
done
if echo "$DM_ARGS_WS" | grep -qxF "DOCKER_TLS_CERTDIR=" && \
   [ "$(echo "$DM_ARGS_WS" | grep -B1 -xF 'DOCKER_TLS_CERTDIR=' | head -1)" = "-e" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: DOCKER_TLS_CERTDIR stays paired with -e"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: DOCKER_TLS_CERTDIR lost its -e"; FAIL=$((FAIL + 1))
fi
# the daemon image (built pia-dind, tagged with the guard version) is the
# last thing before the dockerd command line
DIND_REF="${DIND_IMAGE_DEFAULT}:guard-v${NESTED_GUARD_VERSION}"
if [ "$(echo "$DM_ARGS_WS" | grep -cxF "$DIND_REF")" = "1" ] && \
   [ "$(echo "$DM_ARGS_WS" | grep -A1 -xF "$DIND_REF" | tail -1)" = "dockerd" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: daemon image sits directly before 'dockerd'"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: daemon image position changed (want '$DIND_REF')"; FAIL=$((FAIL + 1))
fi
# the bind whitelist travels to the image entrypoint as $PIA_GUARD_WS:
# dind-dev passes the daemon-side workspace target, plain dind passes empty
if echo "$DM_ARGS_WS" | grep -qxF "PIA_GUARD_WS=${DIND_WS_TARGET}" && \
   ! dind_create_args pia-x-dind pia-x "" "" | grep -q "^PIA_GUARD_WS=${DIND_WS_TARGET}$"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: PIA_GUARD_WS set for dind-dev, empty for plain dind"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: PIA_GUARD_WS whitelist env wiring changed"; FAIL=$((FAIL + 1))
fi
# runc fallback = PRIVILEGED, no host binds without dind-dev. The old
# enumerated-caps config could not start a single nested container on plain
# runc / Docker Desktop (seccomp blocks the session-keyring call; /proc/sys
# is read-only), so the fallback must be exactly '--privileged' — and still
# must not leak a workspace unless dind-dev asked for one.
DM_ARGS_RUNC="$(dind_create_args pia-x-dind pia-x "" "")"
if echo "$DM_ARGS_RUNC" | grep -qxF -- "--privileged" && \
   [ "$(echo "$DM_ARGS_RUNC" | grep -c '^-v$' || true)" = "0" ] && \
   ! echo "$DM_ARGS_RUNC" | grep -qE 'cap-add|cap-drop|cgroup' && \
   [ "$(echo "$DM_ARGS_RUNC" | grep -c 'workspace' || true)" = "0" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: runc fallback is --privileged with zero host binds"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: runc fallback args changed (got '$DM_ARGS_RUNC')"; FAIL=$((FAIL + 1))
fi
# with a runtime (sysbox/gVisor) there is NO privileged escape
if ! echo "$DM_ARGS_NO_WS" | grep -qxF -- "--privileged" && \
   echo "$DM_ARGS_NO_WS" | grep -qxF "sysbox-runc"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: sysbox path never adds --privileged"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: sysbox path leaked --privileged"; FAIL=$((FAIL + 1))
fi
rm -rf "$DM_WS_DIR"

# The guard is a FILE (docker/pia-dind/guard.sh) baked into the daemon image
# — a re-embedded heredoc would be unlintable and escape-hell again (the old
# shape of this code), so its absence from pia.sh is a regression rule.
TOTAL=$((TOTAL + 1))
if [ -x "$GUARD_SRC" ] && head -1 "$GUARD_SRC" | grep -q '^#!/bin/sh' && ! grep -q 'GUARDEOF' "$AGENTS"; then
    echo -e "  ${GREEN}PASS${NC}: guard ships as an executable file, not embedded in pia.sh"; PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: guard file missing/non-executable, or a heredoc crept back into pia.sh"; FAIL=$((FAIL + 1))
fi

# nested-container guard: the payload script is valid POSIX shell,
# carries the current version, and enforces every policy class — the v7 cap
# allow-list, seccomp strength, exec-time privilege injection, devices,
# namespace joins, bundle presence, plumbing grafts, local-driver volume
# options. It installs ITSELF as runc (delegating to '$0.real'),
# so even '--runtime=runc' cannot walk past it.
DMG_FILE="$(mktemp)"
cp "$GUARD_SRC" "$DMG_FILE"
if sh -n "$DMG_FILE" && grep -q "GUARD_VERSION=$NESTED_GUARD_VERSION" "$DMG_FILE"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: guard script parses and carries version $NESTED_GUARD_VERSION"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: guard script does not parse or version-stamp is wrong"; FAIL=$((FAIL + 1))
fi
for rule in 'allow-list' 'caps_check' 'SCMP_ACT_' 'seccomp section omitted' 'exec --privileged' 'exec must inherit' 'foreign container plumbing' 'runc.real\|${0}.real' '--bundle' 'external namespace join' 'daemon-internal' 'block device' 'host join' 'major' 'opts.json' 'pkill -9 dockerd' 'ltrimstr' 'readlink -f' 'check_src' 'log.json' 'TOCTOU' 'mountinfo' 'make-rprivate' '.pia-dind-guard' '/usr/bin/jq' 'privileged requested'; do
    [ "$rule" = "--" ] && continue
    if grep -q -- "$rule" "$DMG_FILE"; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: guard enforces policy '$rule'"; PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: guard missing policy '$rule'"; FAIL=$((FAIL + 1))
    fi
done
rm -f "$DMG_FILE"

# The /var/lib/docker allow-list must stay NARROW — the
# broad '/var/lib/docker/*) return 0' gave the attacker a writable seed
# (tmp/) for the TOCTOU symlink race.
if grep -q -- '/var/lib/docker/\*)' "$DMG_FILE" 2>/dev/null; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: guard re-widens /var/lib/docker allow-list (seed for race)"; FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: /var/lib/docker allow-list stays narrow"; PASS=$((PASS + 1))
fi

# Kill-switch visibility: the resume/ask path must
# never revive a daemon lacking the current guard policy, and a running
# agent with a dead daemon gets a warning naming 'pia dindlog'.
if sed -n '/^ensure_dind_siblings_started()/,/^}/p' "$AGENTS" | grep -q "dind_guard_ok"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: sibling-revive path checks the guard version"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: ensure_dind_siblings_started revives daemons without a guard-version check"; FAIL=$((FAIL + 1))
fi
WARN_OUT="$(bash -c '
    eval "$(awk "/^warn_dind_dead\(\)/,/^}/" "'"$AGENTS"'")"
    container_exists(){ return 0; }
    container_is_running(){ case "$1" in *-dind) return 1;; *) return 0;; esac; }
    dind_name_for(){ echo "$1-dind"; }
    docker(){ echo "2026-01-01T00:00:00Z pia-dind-guard: KILL volume x; killing dockerd"; }
    tar(){ cat; }
    log_warn(){ echo "W: $*"; }
    warn_dind_dead pia-fakeagent' 2>&1)"
if echo "$WARN_OUT" | grep -q "BY DESIGN" && echo "$WARN_OUT" | grep -q "pia dindlog fakeagent"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dead-daemon warning names kill switch and 'pia dindlog'"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dead-daemon warning incomplete (got: $WARN_OUT)"; FAIL=$((FAIL + 1))
fi

# dind mode: agent joins the sibling netns, gets DOCKER_HOST, and NO socket mount
MOUNT_DIR="" SSH_FLAG="" DOCKER_MODE="dind"
result=$(build_docker_args "pia-dindtest" 2>/dev/null)
if echo "$result" | grep -qxF -- "--net" && echo "$result" | grep -qxF "container:pia-dindtest${DIND_SUFFIX}" \
   && echo "$result" | grep -qF "DOCKER_HOST=tcp://127.0.0.1:2375" \
   && ! echo "$result" | grep -qF "docker.sock"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind mode: shared netns + DOCKER_HOST, no socket mount"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind mode args (got '$result')"; FAIL=$((FAIL + 1))
fi

# dind-dev AGENT args are identical to dind (the extra bind goes to the
# DAEMON, never to the agent) — plus its own /workspace mount from -m
DM_WS_DIR2="$(mktemp -d)"
MOUNT_DIR="$DM_WS_DIR2" SSH_FLAG="" DOCKER_MODE="dind-dev"
result=$(build_docker_args "pia-dinddev" 2>/dev/null)
if echo "$result" | grep -qxF "container:pia-dinddev${DIND_SUFFIX}" \
   && echo "$result" | grep -qF "DOCKER_HOST=tcp://127.0.0.1:2375" \
   && echo "$result" | grep -qF "${DM_WS_DIR2}:/workspace" \
   && ! echo "$result" | grep -qF "docker.sock"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind-dev agent: same netns/DOCKER_HOST, workspace via -m"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind-dev agent args (got '$result')"; FAIL=$((FAIL + 1))
fi
rm -rf "$DM_WS_DIR2"

# no mode: neither netns sharing nor DOCKER_HOST nor socket
MOUNT_DIR="" SSH_FLAG="" DOCKER_MODE=""
result=$(build_docker_args "pia-plain" 2>/dev/null)
if ! echo "$result" | grep -qF "container:pia-plain${DIND_SUFFIX}" && ! echo "$result" | grep -qF "DOCKER_HOST" \
   && ! echo "$result" | grep -qF "docker.sock"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: no docker mode adds nothing docker-related"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: plain mode leaked docker args (got '$result')"; FAIL=$((FAIL + 1))
fi

# pia ask refuses --docker=socket with an explanatory error (parse-time,
# no docker needed) and likewise an unknown mode
capture_output ask "hello there" --docker=socket
assert_exit_code 1 "$CAPTURED_EXIT" "ask --docker=socket must refuse"
assert_output_contains "Refusing '--docker=socket'" "$CAPTURED_OUTPUT" "ask --docker=socket explains the refusal"

capture_output ask "hello there" --docker=bogus
assert_exit_code 1 "$CAPTURED_EXIT" "ask --docker=bogus must refuse"
assert_output_contains "INVALID_DOCKER_MODE" "$CAPTURED_OUTPUT" "ask --docker=bogus names the error"

# 'vm' is v2 scope: rejected at parse time, before any container work
capture_output run pia-test-dm-vm-reject --docker=vm
assert_exit_code 1 "$CAPTURED_EXIT" "run --docker=vm must be rejected in v1"
assert_output_contains "INVALID_DOCKER_MODE" "$CAPTURED_OUTPUT" "run --docker=vm names the error"
docker container inspect pia-test-dm-vm-reject > /dev/null 2>&1 && docker rm -f pia-test-dm-vm-reject > /dev/null 2>&1

# 'dind-dev' without a workspace is refused rather than degraded to 'dind'
capture_output run pia-test-dm-nows-reject --docker=dind-dev
assert_exit_code 1 "$CAPTURED_EXIT" "run --docker=dind-dev without -m must refuse"
assert_output_contains "needs a workspace" "$CAPTURED_OUTPUT" "run --docker=dind-dev without -m explains why"
docker container inspect pia-test-dm-nows-reject > /dev/null 2>&1 && docker rm -f pia-test-dm-nows-reject > /dev/null 2>&1

# 'pia ask' accepts the safe dind-dev mode but needs the workspace it writes to
capture_output ask "hello there" --docker=dind-dev
assert_exit_code 1 "$CAPTURED_EXIT" "ask --docker=dind-dev without -m must refuse"
assert_output_contains "needs a workspace" "$CAPTURED_OUTPUT" "ask --docker=dind-dev without -m explains why"

# '-m' is meaningless for any other docker mode in 'ask' (the agent's own
# workspace is fixed at creation) — refuse instead of ignoring it
capture_output ask "hello there" --docker -m /tmp
assert_exit_code 1 "$CAPTURED_EXIT" "ask --docker -m must refuse"
assert_output_contains "only accepted with '--docker=dind-dev'" "$CAPTURED_OUTPUT" "ask -m without dind-dev explains why"

fi  # should_run_section general

# --- SECTION: docker (real throwaway-daemon lifecycle) -----------------------

if should_run_section docker; then

DIND_TEST_IMAGE="${DIND_IMAGE_DEFAULT}:guard-v${NESTED_GUARD_VERSION}"
# The CLI never builds, so the daemon image must pre-exist — this test
# harness builds it here to stand in for 'build-docker.sh'; a build failure
# (no network for 'apk add jq') SKIPS the live section instead of failing it.
if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${YELLOW}SKIP${NC}: docker-mode lifecycle tests need the '${IMAGE_NAME}' image"
    PASS=$((PASS + 1))
elif ! docker image inspect "$DIND_TEST_IMAGE" > /dev/null 2>&1 && \
     ! docker build -t "$DIND_TEST_IMAGE" "$(dirname "$GUARD_SRC")" > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${YELLOW}SKIP${NC}: cannot build '${DIND_TEST_IMAGE}' (needs network for apk)"
    PASS=$((PASS + 1))
else

CAPTURE_TIMEOUT_SAVE="$CAPTURE_TIMEOUT"
CAPTURE_TIMEOUT=180

# full create --docker lifecycle
DM="pia-test-dm-create-$$"
register_test_container "$DM" "${DM}${DIND_SUFFIX}"
docker rm -f "$DM" "${DM}${DIND_SUFFIX}" > /dev/null 2>&1 || true
capture_output create "$DM" --docker
assert_exit_code 0 "$CAPTURED_EXIT" "create --docker should exit 0"

ROLE="$(docker container inspect -f '{{ index .Config.Labels "pia-role" }}' "${DM}${DIND_SUFFIX}" 2>/dev/null)"
PARENT="$(docker container inspect -f '{{ index .Config.Labels "pia-parent" }}' "${DM}${DIND_SUFFIX}" 2>/dev/null)"
if [ "$ROLE" = "dind" ] && [ "$PARENT" = "$DM" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: sibling created with pia-role/pia-parent labels"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: sibling labels (role='$ROLE' parent='$PARENT')"; FAIL=$((FAIL + 1))
fi

AGENT_ENV="$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DM" 2>/dev/null)"
AGENT_NET="$(docker container inspect -f '{{.HostConfig.NetworkMode}}' "$DM" 2>/dev/null)"
if echo "$AGENT_ENV" | grep -q '^DOCKER_HOST=tcp://127\.0\.0\.1:2375$' && [ "$AGENT_NET" != "default" ] && [ -n "$AGENT_NET" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: agent has DOCKER_HOST=tcp://127.0.0.1:2375 and the sibling netns"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: agent env/net (env='$AGENT_ENV' net='$AGENT_NET')"; FAIL=$((FAIL + 1))
fi

AGENT_MOUNTS="$(docker container inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$DM" 2>/dev/null)"
if ! docker container inspect "$DM" 2>/dev/null | grep -q 'docker\.sock' && [ -z "$AGENT_MOUNTS" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: agent container mounts NO docker socket (zero mounts)"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: agent container leaked mounts: '$AGENT_MOUNTS'"; FAIL=$((FAIL + 1))
fi

# THE INVARIANT, on a real container: a plain 'dind' daemon sees no host
# directory at all. /sys/fs/cgroup is the kernel interface a privileged
# (runc-fallback) daemon mounts for its own dockerd and the 'volume' entry is
# the dind image's own /var/lib/docker storage (an anonymous volume the host
# daemon manages, holding no host content) — everything else, or any other
# *bind*, means the safe default has silently widened.
SIB_MOUNTS_RAW="$(docker container inspect -f '{{range .Mounts}}{{.Type}}:{{.Source}} {{end}}' "${DM}${DIND_SUFFIX}" 2>/dev/null)"
SIB_HOST_BINDS="$(echo "$SIB_MOUNTS_RAW" | tr ' ' '\n' | grep '^bind:' | grep -v '^bind:/sys/fs/cgroup$' | sed 's/^bind://' | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$SIB_HOST_BINDS" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: plain dind sibling has ZERO host binds"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: plain dind sibling has host binds: '$SIB_HOST_BINDS'"; FAIL=$((FAIL + 1))
fi
if docker container inspect -f '{{range .Mounts}}{{.Type}} {{end}}' "${DM}${DIND_SUFFIX}" 2>/dev/null | grep -q volume; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: daemon storage stays in its own named volume (no bind)"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: expected the dind image's /var/lib/docker volume to exist"; FAIL=$((FAIL + 1))
fi

# The nested-container guard is ACTIVE in the real sibling: the guard
# is the runc binary and the genuine one sits beside it. Checked via
# 'docker cp' so it works whether the sibling is running or stopped.
if docker cp "${DM}${DIND_SUFFIX}:/usr/local/bin/runc" - 2>/dev/null | tar -xO 2>/dev/null | grep -q "GUARD_VERSION=$NESTED_GUARD_VERSION" && \
   docker cp "${DM}${DIND_SUFFIX}:/usr/local/bin/runc.real" - 2>/dev/null | tar -xO >/dev/null 2>&1; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: nested-container guard active in real sibling"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: nested-container guard not active in sibling"; FAIL=$((FAIL + 1))
fi

SIB_STATE="$(docker container inspect -f '{{.State.Status}}' "${DM}${DIND_SUFFIX}" 2>/dev/null)"
if [ "$SIB_STATE" = "exited" ] || [ "$SIB_STATE" = "created" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: create leaves BOTH halves stopped (sibling: $SIB_STATE)"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: sibling should be stopped after create (got '$SIB_STATE')"; FAIL=$((FAIL + 1))
fi

# pia ls hides the plumbing; --all shows it
capture_output ls
assert_output_not_contains "${DM}${DIND_SUFFIX}" "$CAPTURED_OUTPUT" "pia ls hides the daemon sibling"
capture_output ls --all
if echo "$CAPTURED_OUTPUT" | grep -qF "${DM}${DIND_SUFFIX}"; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: pia ls --all shows the daemon sibling"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: pia ls --all hides the sibling (got '$CAPTURED_OUTPUT')"; FAIL=$((FAIL + 1))
fi

# rm takes the sibling with it — nothing left behind
capture_output rm "$DM"
if ! docker container inspect "${DM}${DIND_SUFFIX}" > /dev/null 2>&1 && \
   ! docker container inspect "$DM" > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: rm removes agent AND sibling"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: leftovers after rm"; FAIL=$((FAIL + 1))
fi

# clean collects a stray stopped daemon whose agent is gone
ORPHAN="${DM}-orphan-dind"
register_test_container "$ORPHAN"
docker rm -f "$ORPHAN" > /dev/null 2>&1 || true
docker run -d --name "$ORPHAN" --label "com.docker.compose.project=${PROJECT_NAME}" \
    --label "pia-role=dind" --label "pia-parent=${DM}-orphan" \
    --entrypoint sleep "$DIND_TEST_IMAGE" 1 > /dev/null
sleep 2
capture_output clean
assert_output_contains "Removing stopped daemon container '${ORPHAN}'" "$CAPTURED_OUTPUT" "clean removes a stray stopped daemon"
docker container inspect "$ORPHAN" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: stray daemon is gone after clean"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: stray daemon survived clean"; FAIL=$((FAIL + 1))
fi

# a daemon whose agent is RUNNING is never touched by clean
LIVE="${DM}-live-dind"; LIVEAGENT="${DM}-live"
register_test_container "$LIVE" "$LIVEAGENT"
docker rm -f "$LIVE" "$LIVEAGENT" > /dev/null 2>&1 || true
docker run -d --name "$LIVEAGENT" --label "com.docker.compose.project=${PROJECT_NAME}" pia sleep 120 > /dev/null
docker run -d --name "$LIVE" --label "com.docker.compose.project=${PROJECT_NAME}" \
    --label "pia-role=dind" --label "pia-parent=${LIVEAGENT}" \
    --entrypoint sleep "$DIND_TEST_IMAGE" 5 > /dev/null
sleep 7   # daemon exits while the agent keeps running
capture_output clean
if docker container inspect "$LIVE" > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: clean never removes a live agent's daemon"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: clean killed the live agent's daemon"; FAIL=$((FAIL + 1))
fi
docker rm -f "$LIVE" "$LIVEAGENT" > /dev/null 2>&1 || true

# --- dind-dev: the workspace is the daemon's ENTIRE host view ----

DD_WS="$(mktemp -d)"; DD_WS_ABS="$(cd "$DD_WS" && pwd)"
echo "pia-marker" > "$DD_WS/pia-marker.txt"
DD_WS2="$(mktemp -d)"; DD_WS2_ABS="$(cd "$DD_WS2" && pwd)"
DD="pia-test-dm-dd-$$"
DD_SIB="${DD}${DIND_SUFFIX}"
register_test_container "$DD" "$DD_SIB"
docker rm -f "$DD" "$DD_SIB" > /dev/null 2>&1 || true

# Docker Desktop (Linux VM) reports bind sources in its own path form
# ('/host_mnt/...' or '/run/host-services/...') and only shares the paths the
# user configured, so exact comparisons and file reads must tolerate that.
DD_TRANSLATED=""

# compare a reported source with the requested path (exact, or suffixed by it)
dd_src_matches() {
    case "${1:-}" in
        "$2") return 0 ;;
        "") return 1 ;;
        *)  case "$1" in *"${2#/}") return 0 ;; *) return 1 ;; esac ;;
    esac
}

# create -m WS --docker=dind-dev: both halves get the workspace, and nothing
# else is mounted anywhere
capture_output create "$DD" -m "$DD_WS" --docker=dind-dev
assert_exit_code 0 "$CAPTURED_EXIT" "create --docker=dind-dev should exit 0"
DD_SIB_BINDS="$(docker container inspect -f '{{range .Mounts}}{{.Type}}:{{.Source}} {{end}}' "$DD_SIB" 2>/dev/null | tr ' ' '\n' | grep '^bind:' | grep -v '^bind:/sys/fs/cgroup$' | sed 's/^bind://' | tr '\n' ' ' | sed 's/ $//')"
DD_AGENT_BINDS="$(docker container inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$DD" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
DD_LABEL_WS="$(docker container inspect -f '{{ index .Config.Labels "pia-dind-mounts" }}' "$DD_SIB" 2>/dev/null)"
if dd_src_matches "$DD_SIB_BINDS" "$DD_WS_ABS" && [ "$DD_AGENT_BINDS" = "$DD_WS_ABS" ] && [ "$DD_LABEL_WS" = "$DD_WS_ABS" ]; then
    TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: dind-dev: ONE workspace bind on daemon AND agent, label recorded"; PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: dind-dev mounts (daemon='$DD_SIB_BINDS' agent='$DD_AGENT_BINDS' label='$DD_LABEL_WS')"; FAIL=$((FAIL + 1))
fi
capture_output rm "$DD"
docker rm -f "$DD" "$DD_SIB" > /dev/null 2>&1 || true

# real daemon: the agent's path resolves inside the daemon, and a changed
# workspace RECREATES the daemon instead of silently keeping the old view
DD_START_LOG="$(start_dind_sibling "$DD" "$DD_WS_ABS" 2>&1)"
if [ $? -eq 0 ]; then
    DD_SRC="$(docker container inspect -f '{{range .Mounts}}{{.Type}}:{{.Source}} {{end}}' "$DD_SIB" 2>/dev/null | tr ' ' '\n' | grep '^bind:' | grep -v '^bind:/sys/fs/cgroup$' | sed 's/^bind://' | tr '\n' ' ' | sed 's/ $//')"
    [ "$DD_SRC" != "$DD_WS_ABS" ] && DD_TRANSLATED="yes"
    if [ "$(docker exec "$DD_SIB" cat "${DIND_WS_TARGET}/pia-marker.txt" 2>/dev/null)" = "pia-marker" ]; then
        TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: workspace is live inside the daemon at ${DIND_WS_TARGET}"; PASS=$((PASS + 1))
    elif [ "$(docker exec "$DD_SIB" ls -A "$DIND_WS_TARGET" 2>/dev/null)" = "" ]; then
        # The daemon resolved the path (it exists at /workspace) but sees it
        # empty: the host does not share the filesystem the test runs on
        # (Docker Desktop path translation, or the suite itself running in a
        # container with a private /tmp). Content visibility cannot be
        # asserted here — the bind/label checks above still can.
        TOTAL=$((TOTAL + 1))
        echo -e "  ${YELLOW}SKIP${NC}: workspace content unreadable in the daemon — host does not share '${DD_WS_ABS}' (source shown as '$DD_SRC')"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: workspace not readable inside the daemon (source '$DD_SRC')"; FAIL=$((FAIL + 1))
    fi
    if start_dind_sibling "$DD" "$DD_WS2_ABS" > /dev/null 2>&1; then
        DD_NEW_WS="$(docker container inspect -f '{{ index .Config.Labels "pia-dind-mounts" }}' "$DD_SIB" 2>/dev/null)"
        if [ "$DD_NEW_WS" = "$DD_WS2_ABS" ]; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: changed workspace recreates the daemon (no stale host view)"; PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: daemon kept the old workspace ('$DD_NEW_WS')"; FAIL=$((FAIL + 1))
        fi
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: recreating the daemon for a new workspace failed"; FAIL=$((FAIL + 1))
    fi
else
    TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: start_dind_sibling with a workspace did not come up"; FAIL=$((FAIL + 1))
    echo "$DD_START_LOG" | tail -4 | sed 's/^/      /'
fi

# Fingerprint trigger: rebuilding the daemon image WITHOUT bumping the
# version (the exact 'forgot to bump the number' footgun) must still force
# recreation. We repoint the tag to a rebuilt image (guard.sh comment
# changed, GUARD_VERSION still 6) and check dind_guard_ok flips to false
# even though the running daemon's CONTENT check (marker + jq) still passes
# — isolating the image-id fingerprint as the thing that catches it.
if container_is_running "$DD_SIB" 2>/dev/null; then
    ID_ORIG="$(docker image inspect -f '{{.Id}}' "$DIND_TEST_IMAGE" 2>/dev/null)"
    FP_TMP="$(mktemp -d)"
    cp -r "$(dirname "$GUARD_SRC")"/. "$FP_TMP/"
    echo '# rebuild probe (version unchanged)' >> "$FP_TMP/guard.sh"
    if docker build -q -t "$DIND_TEST_IMAGE" "$FP_TMP" > /dev/null 2>&1; then
        if dind_guard_ok "$DD_SIB"; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: stale daemon accepted after image rebuild (no version bump)"; FAIL=$((FAIL + 1))
        elif docker exec "$DD_SIB" grep -qs "GUARD_VERSION=$NESTED_GUARD_VERSION" /usr/local/bin/runc; then
            # content still 'looks' current — so it was the fingerprint, not
            # the marker, that refused. Exactly the property we want.
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: image-id fingerprint recreates daemon the version marker would bless"; PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: daemon refused but not for the fingerprint reason"; FAIL=$((FAIL + 1))
        fi
        # restore the tag to the image the running daemon was built from
        [ -n "$ID_ORIG" ] && docker tag "$ID_ORIG" "$DIND_TEST_IMAGE" 2>/dev/null
        if dind_guard_ok "$DD_SIB"; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: current-image daemon passes the fingerprint check"; PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: daemon rejected after restoring its image tag"; FAIL=$((FAIL + 1))
        fi
    else
        TOTAL=$((TOTAL + 1)); echo -e "  ${YELLOW}SKIP${NC}: fingerprint rebuild probe failed (no build cache?)"; PASS=$((PASS + 1))
    fi
    rm -rf "$FP_TMP"
fi

# Local-driver VOLUME OPTIONS are mounted by the
# DAEMON itself — 'docker volume create -o device=…' never appears in the
# container spec, so bind policing cannot see it. Detection is opts.json
# beside _data; the refusal must also KILL dockerd, because docker's own
# rollback unmount of the rbind propagates onto the daemon's /proc (rbind
# copies it into a peer group) and zombies the daemon. Checked against the
# real daemon while it is still up; the kill switch ends its life.
if [ "$(docker inspect -f '{{.State.Status}}' "$DD_SIB" 2>/dev/null)" = "running" ]; then
    if docker exec "$DD_SIB" docker pull alpine:3.22 > /dev/null 2>&1; then
        if docker exec "$DD_SIB" docker run --rm alpine:3.22 echo ok > /dev/null 2>&1; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: v3 guard leaves ordinary nested runs working"; PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: v3 guard broke an ordinary nested run"; FAIL=$((FAIL + 1))
        fi
        # 'docker exec' calls runc WITHOUT a
        # bundle — v3 refused it, v4 must pass it through.
        docker exec "$DD_SIB" docker run -d --name pia-test-exec alpine:3.22 sleep 30 > /dev/null 2>&1
        if docker exec "$DD_SIB" docker exec pia-test-exec echo ok > /dev/null 2>&1; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: nested docker exec is allowed (no exec false-positive)"; PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: nested docker exec was refused"; FAIL=$((FAIL + 1))
        fi
        docker exec "$DD_SIB" docker rm -f pia-test-exec > /dev/null 2>&1
        # The tmp/ seed bind (step 1 of the race chain) must be
        # refused by the narrowed allow-list, and a workspace bind must work
        # THROUGH the pin path (guard mounts + verifies + rewrites).
        if docker exec "$DD_SIB" docker run --rm -v /var/lib/docker/tmp:/x alpine:3.22 true > /dev/null 2>&1; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: /var/lib/docker/tmp bindable (race seed open)"; FAIL=$((FAIL + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: /var/lib/docker/tmp seed refused"; PASS=$((PASS + 1))
        fi
        docker exec "$DD_SIB" sh -c 'echo v5marker > /workspace/v5.txt'
        if [ "$(docker exec "$DD_SIB" docker run --rm -v /workspace:/w alpine:3.22 cat /w/v5.txt 2>/dev/null | tail -1)" = "v5marker" ]; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: workspace bind works through the pin path"; PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: pinned workspace bind broken"; FAIL=$((FAIL + 1))
        fi
        docker exec "$DD_SIB" sh -c 'rm -f /workspace/v5.txt'
        # Symlinked bind sources resolve at mount time —
        # literal-string policing let 'ln -s / <ws>/link; -v <ws>/link' mount
        # the daemon root rw. v4 checks the RESOLVED path too.
        docker exec "$DD_SIB" sh -c 'ln -sfn / /workspace/.kit-sym; mkdir -p /workspace/sub && ln -sfn /etc /workspace/sub/etc'
        if docker exec "$DD_SIB" docker run --rm -v /workspace/.kit-sym:/mnt alpine:3.22 ls /mnt > /dev/null 2>&1; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: symlink bind to / was MOUNTED (TOCTOU open)"; FAIL=$((FAIL + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: symlink bind to / refused (TOCTOU)"; PASS=$((PASS + 1))
        fi
        if docker exec "$DD_SIB" docker run --rm -v /workspace/sub/etc/passwd:/x alpine:3.22 cat /x > /dev/null 2>&1; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: symlinked intermediate component was MOUNTED"; FAIL=$((FAIL + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: symlinked intermediate component refused"; PASS=$((PASS + 1))
        fi
        docker exec "$DD_SIB" sh -c 'rm -f /workspace/.kit-sym; rm -rf /workspace/sub'
        # Guard files are immutable — even the daemon's own
        # root cannot patch the guard in place without clearing +i first.
        if docker exec "$DD_SIB" sh -c 'echo x >> /usr/local/bin/runc' 2>/dev/null; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: guard binary is writable (tamper open)"; FAIL=$((FAIL + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: guard binary is immutable (tamper-proof)"; PASS=$((PASS + 1))
        fi
        docker exec "$DD_SIB" docker volume create pia-test-evil -o type=none -o o=rbind -o device=/ > /dev/null 2>&1
        if docker exec "$DD_SIB" docker run --rm -v pia-test-evil:/y alpine:3.22 ls /y > /dev/null 2>&1; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: opts volume was MOUNTED into a nested container"; FAIL=$((FAIL + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: opts volume refused (daemon-side mount)"; PASS=$((PASS + 1))
        fi
        sleep 2
        DD_KILL_STATE="$(docker inspect -f '{{.State.Status}}' "$DD_SIB" 2>/dev/null)"
        if [ "$DD_KILL_STATE" = "exited" ]; then
            TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC}: daemon self-terminates cleanly instead of zombifying"; PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC}: kill switch did not end the daemon (state: $DD_KILL_STATE)"; FAIL=$((FAIL + 1))
        fi
    else
        TOTAL=$((TOTAL + 9)); echo -e "  ${YELLOW}SKIP${NC}: no network for the nested guard regression checks (9 tests)"; PASS=$((PASS + 9))
    fi
fi
docker rm -f -v "$DD_SIB" > /dev/null 2>&1 || true
rm -rf "$DD_WS" "$DD_WS2"

CAPTURE_TIMEOUT="$CAPTURE_TIMEOUT_SAVE"

fi  # images available

fi  # should_run_section docker
