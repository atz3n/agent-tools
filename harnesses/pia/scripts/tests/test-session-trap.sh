#!/bin/bash

# =============================================================================
# SECTION 22: Session signal traps — a closed terminal must not orphan the
# container. Covers start_session ('run'), attach_session ('resume') and the
# 'ask' cleanup. Only current images are supported (idling entrypoint); the
# session is always an attached 'docker exec'.
#
# Mocked docker only: the shim BLOCKS on 'exec' so the test can signal the
# pia process mid-session (as closing a terminal would) and then check which
# cleanup call the trap made. Also asserts the pre-existing lifecycles still
# hold: normal end stops the container, exec failure (rc 126) leaves it
# running.
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 22: Session signal traps (no orphans on HUP) ===${NC}"

ST_DIR="/tmp/pia-test-sessiontrap-$$"
ST_ID="mockid-trap"
rm -rf "$ST_DIR"; mkdir -p "$ST_DIR"

cat > "$ST_DIR/docker" <<SHIM
#!/bin/bash
echo "docker \$*" >> "$ST_DIR/calls"
st() { cat "$ST_DIR/\$1" 2>/dev/null || echo ""; }
case "\$1" in
    image) exit 0 ;;                          # image inspect (ask preflight)
    run)   exit 0 ;;                          # 'docker run -d'
    start)   exit 0 ;;
    container)                                # 'container inspect' variants
        if printf '%s\n' "\$@" | grep -q 'State.Running'; then echo true
        elif printf '%s\n' "\$@" | grep -q '{{.Id}}'; then echo "$ST_ID"
        else exit 1                            # bare inspect = existence: never pre-exists
        fi
        exit 0 ;;
    exec)
        case "\$(st execmode)" in
            block) sleep 6 ;;
            fail)  exit 126 ;;
        esac
        exit 0 ;;
esac
exit 0
SHIM
chmod +x "$ST_DIR/docker"

# Sourceable copy of pia.sh (everything before the MAIN dispatcher).
ST_LIB="$ST_DIR/lib.sh"
st_main_line=$(grep -n '^# MAIN$' "$AGENTS" | cut -d: -f1)
sed "$((st_main_line - 2)),\$d" "$AGENTS" > "$ST_LIB"

# st_setup EXECMODE — configure the shim for one case ('block', 'fail', or
# empty for a session that ends immediately).
st_setup() {
    printf '%s' "$1" > "$ST_DIR/execmode"
    : > "$ST_DIR/calls"
}

# st_await_attached — wait (max ~5s) until the shim log shows the session
# attached, so the signal is only sent while the trap is armed.
st_await_attached() {
    local i=0
    while [ $i -lt 50 ]; do
        grep -qF 'docker exec' "$ST_DIR/calls" 2>/dev/null && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

# st_run TARGET SIGNAL — run a session target under the shim; SIGNAL empty
# lets the session end normally, otherwise it is sent mid-session. Waits for
# the process to die (the trap must not hang) and leaves the call log in
# ST_CALLS. TARGET 'ask' goes through the real CLI, everything else sources
# the function directly.
st_run() {
    local target="$1" signal="$2" pid i
    # 'exec' so $! IS the session process — a plain subshell would take the
    # signal instead of the trapped bash running the session.
    if [ "$target" = "ask" ]; then
        ( PATH="$ST_DIR:$PATH" exec bash "$AGENTS" ask "hello" < /dev/null > /dev/null 2>&1 ) &
    else
        ( PATH="$ST_DIR:$PATH" exec bash -c "source '$ST_LIB'; $target pia-test-trap" < /dev/null > /dev/null 2>&1 ) &
    fi
    pid=$!
    if [ -n "$signal" ]; then
        st_await_attached
        kill -"$signal" "$pid" 2>/dev/null
    fi
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 100 ]; do
        sleep 0.1; i=$((i + 1))
    done
    # Never wait on a missed trap; the shim's own sleep bounds itself.
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    ST_CALLS=$(cat "$ST_DIR/calls" 2>/dev/null || true)
}

# st_contains PHRASE — 0 when the last run's log contains PHRASE.
st_contains() { printf '%s\n' "$ST_CALLS" | grep -qF -- "$1"; }

st_assert() {
    local ok="$1" description="$2"
    TOTAL=$((TOTAL + 1))
    if [ "$ok" = "yes" ]; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description"
        echo "       Calls: $(printf '%s' "$ST_CALLS" | tr '\n' ';')"
        FAIL=$((FAIL + 1))
    fi
}

# --- Static wiring ----------------------------------------------------------
# One helper definition, three armed call sites (run, resume, ask) and three
# disarms. If a new blocking session path is added without a trap, these
# counts catch it.
n=$(grep -c '^trap_session_signals()' "$AGENTS")
[ "$n" -eq 1 ] && ok=yes || ok=no
st_assert "$ok" "trap_session_signals is defined exactly once (found $n)"

n=$(grep -c '^ *trap_session_signals "' "$AGENTS")
[ "$n" -eq 3 ] && ok=yes || ok=no
st_assert "$ok" "all three blocking session paths arm a signal trap (found $n)"

n=$(grep -c 'trap - HUP INT TERM' "$AGENTS")
[ "$n" -eq 3 ] && ok=yes || ok=no
st_assert "$ok" "every armed trap is disarmed after the exec (found $n)"

# --- start_session ('pia run') -----------------------------------------------
st_setup block
st_run start_session HUP
st_contains "docker stop $ST_ID" && ok=yes || ok=no
st_assert "$ok" "run: SIGHUP mid-session stops the container"

st_setup block
st_run start_session TERM
st_contains "docker stop $ST_ID" && ok=yes || ok=no
st_assert "$ok" "run: SIGTERM mid-session stops the container"

st_setup ""
st_run start_session ""
st_contains "docker stop $ST_ID" && ok=yes || ok=no
st_assert "$ok" "run: normal session end still stops the container"

# --- attach_session ('pia resume') -------------------------------------------
st_setup block
st_run attach_session HUP
st_contains "docker stop $ST_ID" && ok=yes || ok=no
st_assert "$ok" "resume: SIGHUP mid-session stops the container"

st_setup ""
st_run attach_session ""
st_contains "docker stop $ST_ID" && ok=yes || ok=no
st_assert "$ok" "resume: normal session end still stops the container"

# Pre-existing rule: exec could not run pi (rc 126) — leave it running.
st_setup fail
st_run attach_session ""
st_contains "docker stop" && ok=no || ok=yes
st_assert "$ok" "resume: exec failure (rc 126) still leaves the container running"

# --- cmd_ask ('pia ask', ephemeral container) --------------------------------
st_setup block
st_run ask HUP
st_contains "docker rm -f $ST_ID" && ok=yes || ok=no
st_assert "$ok" "ask: SIGHUP mid-run removes the ephemeral container"

st_setup ""
st_run ask ""
st_contains "docker rm -f $ST_ID" && ok=yes || ok=no
st_assert "$ok" "ask: normal end still removes the ephemeral container"

rm -rf "$ST_DIR"
