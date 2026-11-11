#!/bin/bash

# =============================================================================
# SECTION 1: No arguments and help (general)
# =============================================================================
if should_run_section "general"; then
echo ""
echo -e "${YELLOW}=== SECTION 1: No arguments and help ===${NC}"

capture_output
assert_exit_code 1 "$CAPTURED_EXIT" "No arguments should exit 1"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "No arguments should show usage"
assert_output_contains "Commands:" "$CAPTURED_OUTPUT" "No arguments should list commands"

capture_output --help
assert_exit_code 0 "$CAPTURED_EXIT" "--help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "--help should show usage"
assert_output_contains "Examples:" "$CAPTURED_OUTPUT" "--help should show examples"

capture_output -h
assert_exit_code 0 "$CAPTURED_EXIT" "-h should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "-h should show usage"

capture_output help
assert_exit_code 0 "$CAPTURED_EXIT" "help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "help should show usage"
fi

# =============================================================================
# SECTION 2: Unknown command (general)
# =============================================================================
if should_run_section "general"; then
echo ""
echo -e "${YELLOW}=== SECTION 2: Unknown command ===${NC}"

capture_output foobar
assert_exit_code 1 "$CAPTURED_EXIT" "Unknown command should exit 1"
assert_stderr_contains "Unknown command: foobar" "$CAPTURED_OUTPUT" "Should show unknown command error"
fi

# =============================================================================
# SECTION 3: The 'run' command
# =============================================================================
if should_run_section "run"; then
echo ""
echo -e "${YELLOW}=== SECTION 3: The 'run' command ===${NC}"

capture_output run --help
assert_exit_code 0 "$CAPTURED_EXIT" "run --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "run --help should show usage"

capture_output run -h
assert_exit_code 0 "$CAPTURED_EXIT" "run -h should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "run -h should show usage"

capture_output run --unknown
assert_exit_code 1 "$CAPTURED_EXIT" "run --unknown should exit 1"
assert_output_contains "Unknown option:" "$CAPTURED_OUTPUT" "Should show unknown option error"

capture_output run -z
assert_exit_code 1 "$CAPTURED_EXIT" "run -z should exit 1"
assert_output_contains "Unknown option:" "$CAPTURED_OUTPUT" "Should show unknown short option error"

# These parse-check runs may actually create and start containers with the
# given names — register them so cleanup removes them by exact name.
register_test_container pia-test-run-mounter pia-test-run-m pia-test-interleave \
    pia-test-preopts pia-my-test_container_123 pia-agent-abc123 pia-first-name

capture_output run test-run-mounter --mount /tmp
assert_output_not_contains "Unknown option" "$CAPTURED_OUTPUT" "run with --mount /tmp should parse options"

capture_output run test-run-m -m /tmp
assert_output_not_contains "Unknown option" "$CAPTURED_OUTPUT" "run with -m /tmp should parse options"

capture_output run -m /tmp test-interleave --ssh
assert_output_not_contains "Unknown option" "$CAPTURED_OUTPUT" "run with interleaved args should parse"

capture_output run --mount /tmp --ssh test-preopts
assert_output_not_contains "Unknown option" "$CAPTURED_OUTPUT" "run with options before name should parse"

capture_output run my-test_container_123
assert_output_not_contains "Unknown option" "$CAPTURED_OUTPUT" "run with hyphenated name should parse"

capture_output run agent-abc123
assert_output_not_contains "Unknown option" "$CAPTURED_OUTPUT" "run with name agent-abc123 should parse"

capture_output run first-name second-name third-name
assert_output_not_contains "Unknown option" "$CAPTURED_OUTPUT" "run with multiple positional args should take first as name"

# --- Error: --mount as the last argument has no value ---
# Must be a hard error: warn-and-continue used to create a random-named
# container without the requested mount (and outside the test cleanup).

capture_output run --mount
assert_exit_code 1 "$CAPTURED_EXIT" "run --mount without value should exit 1"
assert_output_contains "requires a value" "$CAPTURED_OUTPUT" "run --mount without value should report the missing value"
assert_output_not_contains "Starting agent container" "$CAPTURED_OUTPUT" "run --mount without value should not create a container"

capture_output create --mount
assert_exit_code 1 "$CAPTURED_EXIT" "create --mount without value should exit 1"
assert_output_contains "requires a value" "$CAPTURED_OUTPUT" "create --mount without value should report the missing value"

capture_output restart test-container -m
assert_exit_code 1 "$CAPTURED_EXIT" "restart -m without value should exit 1"
assert_output_contains "requires a value" "$CAPTURED_OUTPUT" "restart -m without value should report the missing value"

# --- Happy path: run creates a new container ---

# Clean up any leftover container
RUN_TEST="pia-test-run-new-$$"
register_test_container "$RUN_TEST"
docker rm -f "$RUN_TEST" > /dev/null 2>&1 || true

# Verify pia image exists (prerequisite)
if docker image inspect pia > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia image exists (prerequisite for run tests)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia image must exist to test run command"
    FAIL=$((FAIL + 1))
fi

# Run with a named container — docker run -it needs a TTY.
# When stdin is /dev/null, docker run fails immediately (no container created).
# We verify the script at least attempts to start the container.
capture_output run "$RUN_TEST"

# Script should report starting the container
if echo "$CAPTURED_OUTPUT" | grep -q "Starting agent container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: run attempts to start the container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: run should attempt to start the container (got '$CAPTURED_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# --- Happy path: run with auto-generated name ---

# Run without a name — should generate one
capture_output run --mount /tmp

# The container gets a random name — register it from the output so cleanup
# removes this exact container (name patterns cannot identify it reliably).
AUTO_NAME="$(echo "$CAPTURED_OUTPUT" | grep -oE 'pia-[a-z0-9]{8}' | head -1)"
register_test_container "$AUTO_NAME"

# Should have attempted to start (output mentions starting or the auto name)
if echo "$CAPTURED_OUTPUT" | grep -qE "(Starting agent|pia-[a-z0-9]{8})"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: run with auto-generated name produces a name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: run with auto-generated name should produce output (got '$CAPTURED_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# --- Happy path: run with --mount option ---

# Clean up
RUN_MOUNT_TEST="pia-test-run-mount-$$"
register_test_container "$RUN_MOUNT_TEST"
docker rm -f "$RUN_MOUNT_TEST" > /dev/null 2>&1 || true

# Run with mount — verify the script attempts to start with the mount
capture_output run "$RUN_MOUNT_TEST" --mount /tmp

# Script should report starting the container
if echo "$CAPTURED_OUTPUT" | grep -q "Starting agent container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: run with --mount attempts to start container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: run with --mount should attempt to start container (got '$CAPTURED_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# --- Error: container already running ---

# Create a running container
RUN_RUNNING="pia-test-run-running-$$"
register_test_container "$RUN_RUNNING"
docker rm -f "$RUN_RUNNING" > /dev/null 2>&1 || true
docker run -d --name "$RUN_RUNNING" alpine:latest sleep 3600 > /dev/null 2>&1

# Verify it's running
if docker ps --filter "name=^${RUN_RUNNING}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test container is running"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test container should be running"
    FAIL=$((FAIL + 1))
fi

# Try to run again — should error
RUNNING_OUTPUT=$()
RUNNING_EXIT=0
RUNNING_OUTPUT=$(timeout 3 bash "$AGENTS" run "$RUN_RUNNING" < /dev/null 2>&1) || RUNNING_EXIT=$?

assert_exit_code 1 "$RUNNING_EXIT" "run should exit 1 when container already running"
assert_output_contains "already running" "$RUNNING_OUTPUT" "run should report already running"
assert_output_contains "pia exec" "$RUNNING_OUTPUT" "run should suggest pia exec"

# --- Happy path: run with stopped container (docker start + exec) ---

# Stop the running container
docker stop "$RUN_RUNNING" > /dev/null 2>&1

# Verify it's stopped
if docker ps -a --filter "name=^${RUN_RUNNING}$" --format '{{.Status}}' 2>/dev/null | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test container is stopped"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test container should be stopped"
    FAIL=$((FAIL + 1))
fi

# Run again — attach_session starts the stopped container with 'docker start'
# and attaches pi via 'docker exec' (which fails on alpine, rc 127, leaving
# the container running on purpose).
RUNNING_OUTPUT=$()
RUNNING_EXIT=0
RUNNING_OUTPUT=$(timeout 3 bash "$AGENTS" run "$RUN_RUNNING" < /dev/null 2>&1) || RUNNING_EXIT=$?

# Container should now be running (started before the session attach).
if docker ps --filter "name=^${RUN_RUNNING}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: run with stopped container started it (container is now running)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: run should have started the stopped container (state: '$(docker ps -a --filter "name=^${RUN_RUNNING}$" --format "{{.Status}}" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# --- Error: invalid mount directory ---

RUN_BAD_MOUNT="pia-test-run-badmount-$$"
register_test_container "$RUN_BAD_MOUNT"
docker rm -f "$RUN_BAD_MOUNT" > /dev/null 2>&1 || true

# Run with non-existent mount dir — should error before checking image
capture_output run "$RUN_BAD_MOUNT" --mount /nonexistent/path/xyz
assert_exit_code 1 "$CAPTURED_EXIT" "run should exit 1 with invalid mount dir"
assert_output_contains "does not exist" "$CAPTURED_OUTPUT" "run should report mount directory does not exist"

# --- Cleanup ---

docker rm -f "$RUN_RUNNING" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 3b: The 'create' command
# =============================================================================
if should_run_section "create"; then
echo ""
echo -e "${YELLOW}=== SECTION 3b: The 'create' command ===${NC}"

capture_output create --help
assert_exit_code 0 "$CAPTURED_EXIT" "create --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "create --help should show usage"

capture_output create --unknown
assert_exit_code 1 "$CAPTURED_EXIT" "create --unknown should exit 1"
assert_output_contains "Unknown option:" "$CAPTURED_OUTPUT" "create should show unknown option error"

# --- Error: invalid mount directory (needs image; validation order matches 'run') ---

# --- Happy path: create makes a stopped container that is not started ---

CREATE_TEST="pia-test-create-new-$$"
register_test_container "$CREATE_TEST"
docker rm -f "$CREATE_TEST" > /dev/null 2>&1 || true

if docker image inspect pia > /dev/null 2>&1; then
    capture_output create pia-test-create-badmount --mount /nonexistent/path/xyz
    assert_exit_code 1 "$CAPTURED_EXIT" "create should exit 1 with invalid mount dir"
    assert_output_contains "does not exist" "$CAPTURED_OUTPUT" "create should report mount directory does not exist"

    capture_output create "$CREATE_TEST" --mount /tmp
    assert_exit_code 0 "$CAPTURED_EXIT" "create should exit 0"
    assert_output_contains "created but not started" "$CAPTURED_OUTPUT" "create should report the container was not started"

    # Container must exist but must NOT be running
    if docker container inspect "$CREATE_TEST" > /dev/null 2>&1; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: create produced an existing container"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: create should have created the container"
        FAIL=$((FAIL + 1))
    fi

    if [ "$(docker container inspect -f '{{.State.Running}}' "$CREATE_TEST" 2>/dev/null)" = "false" ]; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: created container is not running"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: created container should not be running"
        FAIL=$((FAIL + 1))
    fi

    # The mount must be present on the created container
    if docker container inspect "$CREATE_TEST" 2>/dev/null | grep -q '"/workspace"'; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: created container has the /workspace mount"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: created container should have the /workspace mount"
        FAIL=$((FAIL + 1))
    fi

    # --- Error: creating the same name twice ---

    capture_output create "$CREATE_TEST"
    assert_exit_code 1 "$CAPTURED_EXIT" "create should exit 1 when the container already exists"
    assert_output_contains "already exists" "$CAPTURED_OUTPUT" "create should report the container already exists"

    # --- Error: name exists and is RUNNING (different hint branch) ---

    CREATE_DUPRUN="pia-test-create-duprun-$$"
    register_test_container "$CREATE_DUPRUN"
    docker rm -f "$CREATE_DUPRUN" > /dev/null 2>&1 || true
    docker run -d --name "$CREATE_DUPRUN" alpine:latest sleep 3600 > /dev/null 2>&1

    capture_output create "$CREATE_DUPRUN"
    assert_exit_code 1 "$CAPTURED_EXIT" "create should exit 1 when the container is running"
    assert_output_contains "already exists" "$CAPTURED_OUTPUT" "create (running dup) should report already exists"
    assert_output_contains "Stop it with" "$CAPTURED_OUTPUT" "create (running dup) should suggest pia stop/restart"

    docker rm -f "$CREATE_DUPRUN" > /dev/null 2>&1 || true

    # --- Happy path: create with no name auto-generates pia-xxxxxxxx ---

    capture_output create
    assert_exit_code 0 "$CAPTURED_EXIT" "create with no name should exit 0"
    AUTO_NAME=$(echo "$CAPTURED_OUTPUT" | grep -oE 'pia-[a-z0-9]{8}' | head -1)
    if [ -n "$AUTO_NAME" ] && docker container inspect "$AUTO_NAME" > /dev/null 2>&1; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: create auto-generates a name ('${AUTO_NAME}') and the container exists"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: create with no name should produce a real pia-xxxxxxxx container (got '$CAPTURED_OUTPUT')"
        FAIL=$((FAIL + 1))
    fi
    [ -n "$AUTO_NAME" ] && docker rm -f "$AUTO_NAME" > /dev/null 2>&1 || true

    # --- Options pass-through: --docker mounts the Docker socket ---

    CREATE_DOCKER="pia-test-create-docker-$$"
    register_test_container "$CREATE_DOCKER"
    docker rm -f "$CREATE_DOCKER" > /dev/null 2>&1 || true
    capture_output create "$CREATE_DOCKER" --docker
    assert_exit_code 0 "$CAPTURED_EXIT" "create --docker should exit 0"
    if docker container inspect "$CREATE_DOCKER" 2>/dev/null | grep -q '/var/run/docker.sock'; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: created container has the Docker socket bind"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: create --docker should bind /var/run/docker.sock"
        FAIL=$((FAIL + 1))
    fi
    docker rm -f "$CREATE_DOCKER" > /dev/null 2>&1 || true

    # --- Options pass-through: --ssh mounts SSH_AUTH_SOCK ---

    CREATE_SSH="pia-test-create-ssh-$$"
    register_test_container "$CREATE_SSH"
    docker rm -f "$CREATE_SSH" > /dev/null 2>&1 || true
    SSH_SOCK_TMP="/tmp/pia-test-sshsock-$$"
    rm -f "$SSH_SOCK_TMP"
    if command -v python3 > /dev/null 2>&1 && \
       python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$SSH_SOCK_TMP" 2>/dev/null; then
        SSH_AUTH_SOCK="$SSH_SOCK_TMP"
        export SSH_AUTH_SOCK
        capture_output create "$CREATE_SSH" --ssh
        assert_exit_code 0 "$CAPTURED_EXIT" "create --ssh should exit 0"
        if docker container inspect "$CREATE_SSH" 2>/dev/null | grep -q '/tmp/ssh-agent.sock'; then
            TOTAL=$((TOTAL + 1))
            echo -e "  ${GREEN}PASS${NC}: created container has the SSH agent socket bind"
            PASS=$((PASS + 1))
        else
            TOTAL=$((TOTAL + 1))
            echo -e "  ${RED}FAIL${NC}: create --ssh should bind SSH_AUTH_SOCK to /tmp/ssh-agent.sock"
            FAIL=$((FAIL + 1))
        fi
        unset SSH_AUTH_SOCK
        docker rm -f "$CREATE_SSH" > /dev/null 2>&1 || true
    else
        echo -e "  ${YELLOW}SKIP${NC}: cannot create a unix socket fixture (python3 missing) — --ssh pass-through not tested"
    fi
    rm -f "$SSH_SOCK_TMP"

    docker rm -f "$CREATE_TEST" > /dev/null 2>&1 || true
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia image must exist to test create happy path"
    FAIL=$((FAIL + 1))
fi
fi

# =============================================================================
# SECTION 3c: The 'ask' command
# =============================================================================
if should_run_section "ask"; then
echo ""
echo -e "${YELLOW}=== SECTION 3c: The 'ask' command ===${NC}"

# --- Help ---

capture_output ask --help
assert_exit_code 0 "$CAPTURED_EXIT" "ask --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "ask --help should show usage"

# --- Missing prompt ---

capture_output ask
assert_exit_code 1 "$CAPTURED_EXIT" "ask without a prompt should exit 1"
assert_stderr_contains "Please provide a prompt" "$CAPTURED_OUTPUT" "ask without prompt should error"

# --- Named container does not exist ---

# When the first arg names an existing container it is the NAME; here it does
# not exist and a prompt follows, so ask must reject it instead of treating
# everything as an ephemeral prompt.
capture_output ask nonexistent-container-xyz "hello there"
assert_exit_code 1 "$CAPTURED_EXIT" "ask on non-existent named container should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "ask should report the container does not exist"

# --- Happy flow: ask starts a stopped container on demand, then stops it again ---
# The container is plain alpine: 'pi' is not in it, so the docker exec fails
# immediately (exit 127) without invoking any model, while the real
# start-on-demand and stop-afterwards logic still runs.

ASK_STOPPED="pia-test-ask-stopped-$$"
register_test_container "$ASK_STOPPED"
docker rm -f "$ASK_STOPPED" > /dev/null 2>&1 || true
docker run -d --name "$ASK_STOPPED" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$ASK_STOPPED" > /dev/null 2>&1

if [ "$(docker container inspect -f '{{.State.Running}}' "$ASK_STOPPED" 2>/dev/null)" = "false" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ask test container is stopped beforehand"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ask test container should be stopped beforehand"
    FAIL=$((FAIL + 1))
fi

ASK_STOPPED_RC=0
ASK_STOPPED_OUT=$(timeout 15 bash "$AGENTS" ask "$ASK_STOPPED" "hello from test" < /dev/null 2>&1) || ASK_STOPPED_RC=$?

assert_output_contains "Starting stopped container" "$ASK_STOPPED_OUT" "ask should start the stopped container on demand"
assert_exit_code 127 "$ASK_STOPPED_RC" "ask should propagate the docker exec exit code (pi missing → 127)"

# The container must be stopped again — ask only started it for this prompt.
if [ "$(docker container inspect -f '{{.State.Running}}' "$ASK_STOPPED" 2>/dev/null)" = "false" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ask stopped the container it had started"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ask should stop the container it started (state: '$(docker container inspect -f '{{.State.Status}}' "$ASK_STOPPED" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# --- Happy flow: ask on a running container neither restarts nor stops it ---

ASK_RUNNING="pia-test-ask-running-$$"
register_test_container "$ASK_RUNNING"
docker rm -f "$ASK_RUNNING" > /dev/null 2>&1 || true
docker run -d --name "$ASK_RUNNING" alpine:latest sleep 3600 > /dev/null 2>&1

ASK_RUNNING_RC=0
ASK_RUNNING_OUT=$(timeout 15 bash "$AGENTS" ask "$ASK_RUNNING" "hello from test" < /dev/null 2>&1) || ASK_RUNNING_RC=$?

assert_output_not_contains "Starting stopped container" "$ASK_RUNNING_OUT" "ask should not restart an already running container"

if docker ps --filter "name=^${ASK_RUNNING}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ask left a running container running"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ask should not stop a container it did not start (state: '$(docker ps -a --filter "name=^${ASK_RUNNING}$" --format "{{.Status}}" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---

docker rm -f "$ASK_STOPPED" "$ASK_RUNNING" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 4: The 'stop' command
# =============================================================================
if should_run_section "stop"; then
echo ""
echo -e "${YELLOW}=== SECTION 4: The 'stop' command ===${NC}"

capture_output stop --help
assert_exit_code 0 "$CAPTURED_EXIT" "stop --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "stop --help should show usage"

capture_output stop -h
assert_exit_code 0 "$CAPTURED_EXIT" "stop -h should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "stop -h should show usage"

capture_output stop
assert_exit_code 1 "$CAPTURED_EXIT" "stop without name should exit 1"
assert_stderr_contains "Please provide a container name" "$CAPTURED_OUTPUT" "Should require container name"

capture_output stop nonexistent-container-xyz
assert_exit_code 1 "$CAPTURED_EXIT" "stop non-existent should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "Should show container does not exist"

capture_output stop --help foo
assert_exit_code 0 "$CAPTURED_EXIT" "stop --help should exit 0 even with extra args"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "stop --help should show usage"

# --- Happy path: stop a running container ---

STOP_TEST="pia-test-stop-run-$$"
register_test_container "$STOP_TEST"
docker rm -f "$STOP_TEST" > /dev/null 2>&1 || true
docker run -d --name "$STOP_TEST" alpine:latest sleep 3600 > /dev/null 2>&1

# Verify container is running
if docker ps --filter "name=^${STOP_TEST}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test container is running before stop"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test container should be running"
    FAIL=$((FAIL + 1))
fi

# Stop the container — docker stop may hang in this environment, so we
# verify the script at least attempts to stop it, then force-stop with kill
STOP_OUTPUT=$()
STOP_EXIT=0
STOP_OUTPUT=$(timeout 3 bash "$AGENTS" stop "$STOP_TEST" < /dev/null 2>&1) || STOP_EXIT=$?
assert_output_contains "Stopping container" "$STOP_OUTPUT" "stop should report stopping"

# Force-stop the container (docker stop hangs in this env)
docker kill "$STOP_TEST" > /dev/null 2>&1 || true

# Verify container is now stopped
if docker ps -a --filter "name=^${STOP_TEST}$" --format '{{.Status}}' 2>/dev/null | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: container was stopped (force-killed)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: container should be stopped (state: '$(docker ps -a --filter "name=^${STOP_TEST}$" --format "{{.Status}}" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# --- Already stopped: stop an already stopped container ---

capture_output stop "$STOP_TEST"
assert_exit_code 0 "$CAPTURED_EXIT" "stop already stopped should exit 0"
assert_output_contains "already stopped" "$CAPTURED_OUTPUT" "stop should report already stopped"

# --- Container with prefix missing ---

# Create a new running container
STOP_PREFIX="pia-test-stop-prefix-$$"
register_test_container "$STOP_PREFIX"
docker rm -f "$STOP_PREFIX" > /dev/null 2>&1 || true
docker run -d --name "$STOP_PREFIX" alpine:latest sleep 3600 > /dev/null 2>&1

# Stop with prefix already present — verify script attempts to stop, then force-kill
STOP_PREFIX_OUTPUT=$()
STOP_PREFIX_EXIT=0
STOP_PREFIX_OUTPUT=$(timeout 3 bash "$AGENTS" stop "$STOP_PREFIX" < /dev/null 2>&1) || STOP_PREFIX_EXIT=$?
assert_output_contains "Stopping container" "$STOP_PREFIX_OUTPUT" "stop should report stopping"
docker kill "$STOP_PREFIX" > /dev/null 2>&1 || true

# Verify stopped
if docker ps -a --filter "name=^${STOP_PREFIX}$" --format '{{.Status}}' 2>/dev/null | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: stop works with full prefixed name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: container should be stopped"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---

docker rm -f "$STOP_TEST" "$STOP_PREFIX" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 5: The 'remove' command
# =============================================================================
if should_run_section "remove"; then
echo ""
echo -e "${YELLOW}=== SECTION 5: The 'remove' command ===${NC}"

capture_output remove --help
assert_exit_code 0 "$CAPTURED_EXIT" "remove --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "remove --help should show usage"

capture_output remove -h
assert_exit_code 0 "$CAPTURED_EXIT" "remove -h should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "remove -h should show usage"

capture_output remove
assert_exit_code 1 "$CAPTURED_EXIT" "remove without name should exit 1"
assert_stderr_contains "Please provide a container name" "$CAPTURED_OUTPUT" "Should require container name"

capture_output remove nonexistent-container-xyz
assert_exit_code 1 "$CAPTURED_EXIT" "remove non-existent should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "Should show container does not exist"

# --- 'rm' alias ---

capture_output rm nonexistent-container-xyz
assert_exit_code 1 "$CAPTURED_EXIT" "rm non-existent should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "rm should show container does not exist"
fi

# =============================================================================
# SECTION 6: The 'list' command
# =============================================================================
if should_run_section "list"; then
echo ""
echo -e "${YELLOW}=== SECTION 6: The 'list' command ===${NC}"

capture_output list
assert_exit_code 0 "$CAPTURED_EXIT" "list should exit 0"
assert_output_contains "Pi Agent Containers:" "$CAPTURED_OUTPUT" "list should show header"
assert_output_contains "NAME" "$CAPTURED_OUTPUT" "list should show NAME column"
assert_output_contains "STATUS" "$CAPTURED_OUTPUT" "list should show STATUS column"
assert_output_contains "CREATED" "$CAPTURED_OUTPUT" "list should show CREATED column"

# 'list' takes no arguments — rejecting them is the contract (an ignored
# argument would make a typo look like a filter that matched nothing).
capture_output list extra-arg
assert_exit_code 1 "$CAPTURED_EXIT" "list with an argument should fail"
assert_output_contains "does not take arguments" "$CAPTURED_OUTPUT" "list should reject arguments"
assert_output_contains "docker ps -a --filter name=^pia-extra-arg" "$CAPTURED_OUTPUT" "list should point at a docker filter"

capture_output list --help
assert_exit_code 0 "$CAPTURED_EXIT" "list --help should exit 0"
assert_output_contains "Lists every agent container" "$CAPTURED_OUTPUT" "list --help should explain the command"

# Verify the empty-state message (no pia-* containers should exist in test env)
# — needs a fresh capture, the assertions above leave --help output behind
capture_output list
if echo "$CAPTURED_OUTPUT" | grep -qE "(no agent containers found|NAME.*STATUS.*CREATED)"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: list shows expected output format"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: list output unexpected (got '$CAPTURED_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# --- Happy path: list shows running and stopped pia-* containers ---

# Create one running and one stopped pia-* container
LS_RUNNING="pia-test-ls-run-$$"
register_test_container "$LS_RUNNING"
LS_STOPPED="pia-test-ls-stop-$$"
register_test_container "$LS_STOPPED"
docker rm -f "$LS_RUNNING" "$LS_STOPPED" > /dev/null 2>&1 || true
docker run -d --name "$LS_RUNNING" alpine:latest sleep 3600 > /dev/null 2>&1
docker run -d --name "$LS_STOPPED" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$LS_STOPPED" > /dev/null 2>&1

# Verify both containers exist
docker ps -a --filter "name=^${LS_RUNNING}$" > /dev/null 2>&1
RUNNING_EXISTS=$?
docker ps -a --filter "name=^${LS_STOPPED}$" > /dev/null 2>&1
STOPPED_EXISTS=$?

if [ $RUNNING_EXISTS -eq 0 ] && [ $STOPPED_EXISTS -eq 0 ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test containers created for list test"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test containers should exist"
    FAIL=$((FAIL + 1))
fi

# Run ls — it should show both containers
capture_output list

# Both container names should appear in the output
if echo "$CAPTURED_OUTPUT" | grep -q "$LS_RUNNING"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: list shows running container name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: list should show running container name"
    FAIL=$((FAIL + 1))
fi

if echo "$CAPTURED_OUTPUT" | grep -q "$LS_STOPPED"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: list shows stopped container name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: list should show stopped container name"
    FAIL=$((FAIL + 1))
fi

# Verify status columns show different values for each container
running_status=$(echo "$CAPTURED_OUTPUT" | grep "$LS_RUNNING" | awk '{print $2}')
stopped_status=$(echo "$CAPTURED_OUTPUT" | grep "$LS_STOPPED" | awk '{print $2}')

if echo "$running_status" | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: list shows running status for running container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: list should show running status (got '$running_status')"
    FAIL=$((FAIL + 1))
fi

if echo "$stopped_status" | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: list shows exited status for stopped container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: list should show exited status (got '$stopped_status')"
    FAIL=$((FAIL + 1))
fi

# --- Non-pia-* containers are filtered out ---

# Create a non-pia container
NON_PIA="not-pia-container-$$"
register_test_container "$NON_PIA"
docker rm -f "$NON_PIA" > /dev/null 2>&1 || true
docker run -d --name "$NON_PIA" alpine:latest sleep 3600 > /dev/null 2>&1

# Run ls — the non-pia container should NOT appear
capture_output list

if ! echo "$CAPTURED_OUTPUT" | grep -q "$NON_PIA"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: list filters out non-pia-* containers"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: list should not show non-pia-* containers"
    FAIL=$((FAIL + 1))
fi

# --- Containers in 'Created' state (from 'create') are listed ---

LS_CREATED="pia-test-ls-created-$$"
register_test_container "$LS_CREATED"
docker rm -f "$LS_CREATED" > /dev/null 2>&1 || true
if docker image inspect pia > /dev/null 2>&1; then
    timeout 10 bash "$AGENTS" create "$LS_CREATED" < /dev/null > /dev/null 2>&1 || true

    capture_output list

    if echo "$CAPTURED_OUTPUT" | grep -q "$LS_CREATED"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: list lists a container in Created state"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: list should list a container in Created state"
        FAIL=$((FAIL + 1))
    fi

    if echo "$CAPTURED_OUTPUT" | grep "$LS_CREATED" | grep -q "Created"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: list shows 'Created' status for a never-started container"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: list should show 'Created' status (got '$(echo "$CAPTURED_OUTPUT" | grep "$LS_CREATED")')"
        FAIL=$((FAIL + 1))
    fi

    docker rm -f "$LS_CREATED" > /dev/null 2>&1 || true
else
    echo -e "  ${YELLOW}SKIP${NC}: pia image missing — Created-state list test skipped"
fi

# --- 'ls' alias ---

capture_output ls
assert_exit_code 0 "$CAPTURED_EXIT" "ls should exit 0"
assert_output_contains "Pi Agent Containers:" "$CAPTURED_OUTPUT" "ls should show header"

# --- Cleanup ---

docker rm -f "$LS_RUNNING" "$LS_STOPPED" "$NON_PIA" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 7: The 'restart' command
# =============================================================================
if should_run_section "restart"; then
echo ""
echo -e "${YELLOW}=== SECTION 7: The 'restart' command ===${NC}"

capture_output restart --help
assert_exit_code 0 "$CAPTURED_EXIT" "restart --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "restart --help should show usage"

capture_output restart -h
assert_exit_code 0 "$CAPTURED_EXIT" "restart -h should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "restart -h should show usage"

capture_output restart
assert_exit_code 1 "$CAPTURED_EXIT" "restart without name should exit 1"
assert_stderr_contains "Please provide a container name to restart" "$CAPTURED_OUTPUT" "Should require name"

capture_output restart nonexistent-container-xyz
assert_exit_code 1 "$CAPTURED_EXIT" "restart non-existent should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "Should show container does not exist"

capture_output restart test-container --unknown
assert_exit_code 1 "$CAPTURED_EXIT" "restart with unknown option should exit 1"
assert_output_contains "Unknown option:" "$CAPTURED_OUTPUT" "Should show unknown option error"

capture_output restart test-container -m /tmp
assert_exit_code 1 "$CAPTURED_EXIT" "restart with -m should still check container existence"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "Should show container does not exist"

# --- Happy path: restart a running container ---

# Verify pia image exists (prerequisite)
if docker image inspect pia > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia image exists (prerequisite for restart tests)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia image must exist to test restart command"
    FAIL=$((FAIL + 1))
fi

RESTART_TEST="pia-test-restart-run-$$"
register_test_container "$RESTART_TEST"
RESTART_OLD_ID=""

# Create initial container and capture its ID
docker rm -f "$RESTART_TEST" > /dev/null 2>&1 || true
docker run -d --name "$RESTART_TEST" alpine:latest sleep 3600 > /dev/null 2>&1
RESTART_OLD_ID=$(docker inspect --format '{{.Id}}' "$RESTART_TEST" 2>/dev/null)

# Verify container is running
if docker ps --filter "name=^${RESTART_TEST}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test container is running before restart"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test container should be running"
    FAIL=$((FAIL + 1))
fi

# Restart the container — docker stop may hang, so we use a longer timeout
# and verify the script went through the full restart flow
RESTART_OUTPUT=$()
RESTART_EXIT=0
RESTART_OUTPUT=$(timeout 15 bash "$AGENTS" restart "$RESTART_TEST" < /dev/null 2>&1) || RESTART_EXIT=$?

# Verify the script went through the restart flow
if echo "$RESTART_OUTPUT" | grep -q "Stopping container" && \
   echo "$RESTART_OUTPUT" | grep -q "Removing container" && \
   echo "$RESTART_OUTPUT" | grep -q "Starting fresh agent container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: restart went through stop → rm → run flow"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: restart should report stop/rm/start (got '$RESTART_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# Verify the old container is gone
if [ -n "$RESTART_OLD_ID" ] && ! docker inspect "$RESTART_OLD_ID" > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: old container was removed during restart"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: old container should have been removed"
    FAIL=$((FAIL + 1))
fi

# Verify a new container exists with the same name
# Note: docker run -it fails without a TTY, so the new container may not exist.
# We check that the script at least attempted to create it.
if echo "$RESTART_OUTPUT" | grep -q "Starting fresh agent container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: restart attempted to create new container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: restart should attempt to create new container"
    FAIL=$((FAIL + 1))
fi

# Restart should work on a stopped container too
# Stop the current container
docker stop "$RESTART_TEST" > /dev/null 2>&1 || docker kill "$RESTART_TEST" > /dev/null 2>&1 || true
docker rm -f "$RESTART_TEST" > /dev/null 2>&1 || true

# Create a new container
RESTART_TEST2="pia-test-restart-stop-$$"
register_test_container "$RESTART_TEST2"
docker run -d --name "$RESTART_TEST2" alpine:latest sleep 3600 > /dev/null 2>&1
RESTART_OLD_ID2=$(docker inspect --format '{{.Id}}' "$RESTART_TEST2" 2>/dev/null)

# Stop it (simulate stopped state)
docker stop "$RESTART_TEST2" > /dev/null 2>&1 || docker kill "$RESTART_TEST2" > /dev/null 2>&1 || true

# Restart should stop (already stopped), remove, and create fresh
RESTART2_OUTPUT=$()
RESTART2_EXIT=0
RESTART2_OUTPUT=$(timeout 15 bash "$AGENTS" restart "$RESTART_TEST2" < /dev/null 2>&1) || RESTART2_EXIT=$?

# Verify the script went through the restart flow
if echo "$RESTART2_OUTPUT" | grep -q "Removing container" && \
   echo "$RESTART2_OUTPUT" | grep -q "Starting fresh agent container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: restart works on stopped container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: restart should report rm/start (got '$RESTART2_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# Verify old container is gone
if [ -n "$RESTART_OLD_ID2" ] && ! docker inspect "$RESTART_OLD_ID2" > /dev/null 2>&1; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: old stopped container was removed during restart"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: old stopped container should have been removed"
    FAIL=$((FAIL + 1))
fi

# Verify new container creation was attempted
if echo "$RESTART2_OUTPUT" | grep -q "Starting fresh agent container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: restart attempted to create new container from stopped state"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: restart should attempt to create new container"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---

docker rm -f "$RESTART_TEST" "$RESTART_TEST2" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 8: The 'exec' command
# =============================================================================
if should_run_section "exec"; then
echo ""
echo -e "${YELLOW}=== SECTION 8: The 'exec' command ===${NC}"

capture_output exec --help
assert_exit_code 0 "$CAPTURED_EXIT" "exec --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "exec --help should show usage"
assert_output_contains "Execute a command" "$CAPTURED_OUTPUT" "exec --help should describe command execution"

capture_output exec -h
assert_exit_code 0 "$CAPTURED_EXIT" "exec -h should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "exec -h should show usage"

capture_output exec
assert_exit_code 1 "$CAPTURED_EXIT" "exec without name should exit 1"
assert_stderr_contains "Please provide a container name" "$CAPTURED_OUTPUT" "Should require container name"

capture_output exec nonexistent-container-xyz
assert_exit_code 1 "$CAPTURED_EXIT" "exec non-existent should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "Should show container does not exist"

capture_output exec nonexistent-container-xyz ls -la /
assert_exit_code 1 "$CAPTURED_EXIT" "exec with cmd should still check container existence"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "Should show container does not exist"

# --- Happy path: exec with a command ---

# Create a running container (use debian for bash support)
EXEC_TEST="pia-test-exec-run-$$"
register_test_container "$EXEC_TEST"
docker rm -f "$EXEC_TEST" > /dev/null 2>&1 || true
docker run -d --name "$EXEC_TEST" debian:latest sleep 3600 > /dev/null 2>&1

# Verify container is running
if docker ps --filter "name=^${EXEC_TEST}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test container is running before exec"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test container should be running"
    FAIL=$((FAIL + 1))
fi

# Exec with a command should work
EXEC_OUTPUT=$()
EXEC_EXIT=0
EXEC_OUTPUT=$(timeout 5 bash "$AGENTS" exec "$EXEC_TEST" echo "hello-from-container" < /dev/null 2>&1) || EXEC_EXIT=$?

if echo "$EXEC_OUTPUT" | grep -q "hello-from-container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: exec ran command and captured output"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: exec should run command (got '$EXEC_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# Exec with a more complex command
EXEC_OUTPUT2=$()
EXEC_EXIT2=0
EXEC_OUTPUT2=$(timeout 5 bash "$AGENTS" exec "$EXEC_TEST" ls /tmp < /dev/null 2>&1) || EXEC_EXIT2=$?

if echo "$EXEC_OUTPUT2" | grep -q "^/tmp$\|^$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: exec ran ls command successfully"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: exec should run ls command (got '$EXEC_OUTPUT2')"
    FAIL=$((FAIL + 1))
fi

# Exec on a stopped container should fail
# Stop the container
docker stop "$EXEC_TEST" > /dev/null 2>&1 || docker kill "$EXEC_TEST" > /dev/null 2>&1 || true

# Verify container is stopped
if docker ps -a --filter "name=^${EXEC_TEST}$" --format '{{.Status}}' 2>/dev/null | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test container is stopped"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test container should be stopped"
    FAIL=$((FAIL + 1))
fi

# Exec on stopped container should error
EXEC_STOPPED_OUTPUT=$()
EXEC_STOPPED_EXIT=0
EXEC_STOPPED_OUTPUT=$(timeout 3 bash "$AGENTS" exec "$EXEC_TEST" echo test < /dev/null 2>&1) || EXEC_STOPPED_EXIT=$?

assert_exit_code 1 "$EXEC_STOPPED_EXIT" "exec on stopped container should exit 1"
assert_output_contains "not running" "$EXEC_STOPPED_OUTPUT" "exec should report container not running"
assert_output_contains "pia run" "$EXEC_STOPPED_OUTPUT" "exec should suggest pia run"

# --- Exec with interactive shell (no command) ---

# Start the container again
docker start "$EXEC_TEST" > /dev/null 2>&1 || true

# Exec without a command should attempt interactive shell (will hang, timeout kills it)
EXEC_INTERACTIVE_OUTPUT=$()
EXEC_INTERACTIVE_EXIT=0
EXEC_INTERACTIVE_OUTPUT=$(timeout 3 bash "$AGENTS" exec "$EXEC_TEST" < /dev/null 2>&1) || EXEC_INTERACTIVE_EXIT=$?

# The script should attempt to exec (docker exec -it will hang without TTY)
# We can't verify the output easily since it hangs, but we check it didn't error
if echo "$EXEC_INTERACTIVE_OUTPUT" | grep -q "not running\|does not exist\|Please provide"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: exec interactive should not error (got '$EXEC_INTERACTIVE_OUTPUT')"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: exec interactive shell attempted (timed out as expected)"
    PASS=$((PASS + 1))
fi

# --- Cleanup ---

docker rm -f "$EXEC_TEST" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 9: The 'clean' command
# =============================================================================
if should_run_section "clean"; then
echo ""
echo -e "${YELLOW}=== SECTION 9: The 'clean' command ===${NC}"

# --- Argument handling: an ignored argument must not mean 'clean everything' ---
capture_output clean some-name
assert_exit_code 1 "$CAPTURED_EXIT" "clean with an argument should fail"
assert_output_contains "does not take arguments" "$CAPTURED_OUTPUT" "clean should reject arguments"
assert_output_contains "pia rm <NAME>" "$CAPTURED_OUTPUT" "clean should point at 'rm <NAME>'"

# --help must print usage, not remove containers
capture_output clean --help
assert_exit_code 0 "$CAPTURED_EXIT" "clean --help should exit 0"
assert_output_contains "Removes every stopped agent container" "$CAPTURED_OUTPUT" "clean --help should explain the command"
assert_output_not_contains "Removing all stopped agent containers" "$CAPTURED_OUTPUT" "clean --help must not start cleaning"

# --- Empty state: no stopped containers ---

capture_output clean
assert_exit_code 0 "$CAPTURED_EXIT" "clean should exit 0"
assert_output_contains "Removing all stopped agent containers" "$CAPTURED_OUTPUT" "clean should show starting message"

# Verify it reports no stopped containers (none should exist in test env)
if echo "$CAPTURED_OUTPUT" | grep -qE "(No stopped agent containers to remove|Removed [0-9]+ stopped)"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: clean reports stopped container count"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: clean output unexpected (got '$CAPTURED_OUTPUT')"
    FAIL=$((FAIL + 1))
fi

# --- Happy path: clean removes stopped containers ---

# Create two stopped containers for pruning
CLEAN_TEST_1="pia-test-clean-1-$$"
register_test_container "$CLEAN_TEST_1"
CLEAN_TEST_2="pia-test-clean-2-$$"
register_test_container "$CLEAN_TEST_2"
docker rm -f "$CLEAN_TEST_1" "$CLEAN_TEST_2" > /dev/null 2>&1 || true
docker run -d --name "$CLEAN_TEST_1" alpine:latest sleep 3600 > /dev/null 2>&1
docker run -d --name "$CLEAN_TEST_2" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$CLEAN_TEST_1" > /dev/null 2>&1
docker stop "$CLEAN_TEST_2" > /dev/null 2>&1

# Verify both are stopped
stopped_count=$(docker ps -a --filter "name=^pia-test-clean" --filter "status=exited" --format '{{.Names}}' 2>/dev/null | wc -l)
if [ "$stopped_count" -ge 2 ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: created $stopped_count stopped containers for clean test"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: should have 2 stopped containers (got $stopped_count)"
    FAIL=$((FAIL + 1))
fi

# Run clean — it should remove both stopped containers
capture_output clean
assert_exit_code 0 "$CAPTURED_EXIT" "clean should exit 0"
assert_output_contains "Removed 2 stopped container" "$CAPTURED_OUTPUT" "clean should report removing 2 containers"

# Verify both containers are gone
for container in "$CLEAN_TEST_1" "$CLEAN_TEST_2"; do
    if ! docker ps -a --filter "name=^${container}$" --format '{{.Names}}' 2>/dev/null | grep -q "$container"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: '$container' was removed by clean"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: '$container' should have been removed by clean"
        FAIL=$((FAIL + 1))
    fi
done

# --- Kept containers (pia-keep-*) are NOT cleaned ---

KEEP_CLEAN="pia-keep-test-clean-$$"
register_test_container "$KEEP_CLEAN"
PLAIN_CLEAN="pia-test-clean-3-$$"
register_test_container "$PLAIN_CLEAN"
docker rm -f "$KEEP_CLEAN" "$PLAIN_CLEAN" > /dev/null 2>&1 || true
docker run -d --name "$KEEP_CLEAN" alpine:latest sleep 3600 > /dev/null 2>&1
docker run -d --name "$PLAIN_CLEAN" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$KEEP_CLEAN" "$PLAIN_CLEAN" > /dev/null 2>&1

# Clean should remove only the non-kept stopped container
capture_output clean
assert_exit_code 0 "$CAPTURED_EXIT" "clean should exit 0 with kept containers"
assert_output_contains "Removed 1 stopped container" "$CAPTURED_OUTPUT" "clean should skip the kept container in the count"
assert_output_contains "Skipping protected container '${KEEP_CLEAN}'" "$CAPTURED_OUTPUT" "clean should report skipping the protected container"

if docker ps -a --filter "name=^${KEEP_CLEAN}$" --format '{{.Names}}' 2>/dev/null | grep -q "$KEEP_CLEAN"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: kept container '${KEEP_CLEAN}' survived clean"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: kept container '${KEEP_CLEAN}' should NOT have been removed by clean"
    FAIL=$((FAIL + 1))
fi

if ! docker ps -a --filter "name=^${PLAIN_CLEAN}$" --format '{{.Names}}' 2>/dev/null | grep -q "$PLAIN_CLEAN"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: non-kept stopped container '${PLAIN_CLEAN}' was removed by clean"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: non-kept stopped container '${PLAIN_CLEAN}' should have been removed by clean"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---

docker rm -f "$KEEP_CLEAN" > /dev/null 2>&1 || true

# --- Running containers are NOT cleaned ---

# Create a running container
RUNNING_TEST="pia-test-running-$$"
register_test_container "$RUNNING_TEST"
docker rm -f "$RUNNING_TEST" > /dev/null 2>&1 || true
docker run -d --name "$RUNNING_TEST" alpine:latest sleep 3600 > /dev/null 2>&1

# Verify it is running
if docker ps --filter "name=^${RUNNING_TEST}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: running container is up before clean"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: running container should be up"
    FAIL=$((FAIL + 1))
fi

# Run clean — the running container should survive
capture_output clean

if docker ps --filter "name=^${RUNNING_TEST}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: running container was NOT removed by clean"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: running container should NOT have been removed by clean"
    FAIL=$((FAIL + 1))
fi

# --- Mixed state: one stopped, one running ---

# Stop the previously running container
docker stop "$RUNNING_TEST" > /dev/null 2>&1 || true

# Create a new running container
NEW_RUNNING="pia-test-running-2-$$"
register_test_container "$NEW_RUNNING"
docker rm -f "$NEW_RUNNING" > /dev/null 2>&1 || true
docker run -d --name "$NEW_RUNNING" alpine:latest sleep 3600 > /dev/null 2>&1

# Clean should only remove the stopped one, not the new running one
capture_output clean
assert_exit_code 0 "$CAPTURED_EXIT" "clean should exit 0 with mixed state"
assert_output_contains "Removed 1 stopped container" "$CAPTURED_OUTPUT" "clean should report removing only stopped containers"

# Verify the stopped container is gone
if ! docker ps -a --filter "name=^${RUNNING_TEST}$" --format '{{.Names}}' 2>/dev/null | grep -q "$RUNNING_TEST"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: stopped container was removed"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: stopped container should have been removed"
    FAIL=$((FAIL + 1))
fi

# Verify the running container still exists
if docker ps --filter "name=^${NEW_RUNNING}$" --format '{{.Names}}' 2>/dev/null | grep -q "$NEW_RUNNING"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: running container still exists after clean"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: running container should still exist after clean"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---

docker rm -f "$RUNNING_TEST" "$NEW_RUNNING" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 10: The 'resume' command
# =============================================================================
if should_run_section "resume"; then
echo ""
echo -e "${YELLOW}=== SECTION 10: The 'resume' command ===${NC}"

# --- Isolation helpers ---

# Mirror of cmd_resume's selection: the exited pia-* container that stopped
# last. 'docker ps' sorts by creation time, so the stop time is read from
# State.FinishedAt via 'docker inspect'.
resume_target() {
    local ids
    ids=$(docker ps -a --filter "name=^pia-" --filter "status=exited" --format '{{.ID}}' 2>/dev/null | tr '\n' ' ')
    [ -n "${ids// /}" ] || return 0
    # shellcheck disable=SC2086
    docker inspect --format $'{{.State.FinishedAt}}\t{{.Name}}' $ids 2>/dev/null | awk -F'\t' '{
        ts = $1; sub(/Z$/, "", ts); name = $2; sub(/^\//, "", name); frac = ""
        if (ts ~ /\./) { frac = ts; sub(/^[^.]*\./, "", frac); sub(/\..*$/, "", ts) }
        printf "%s\t%s\t%s\n", ts, substr(frac "000000000", 1, 9), name
    }' | sort | tail -1 | cut -f3
}

# True if any stopped agent containers exist that this suite did not create.
# Such containers would hijack the 'empty environment' assertions (and
# would be started by resume), so those tests skip when they are present.
foreign_stopped_present() {
    local n
    n=$(docker ps -a --filter "name=^pia-" --filter "status=exited" --format '{{.Names}}' 2>/dev/null \
        | grep -vE '^(pia-test-|pia-keep-test-|pia-keep-renamed-|pia-keep-conflict-|pia-my-test-container)' | wc -l)
    [ "$n" -gt 0 ]
}

# Remove stopped leftovers from earlier sections so they cannot hijack the
# resume target or the empty-environment checks below.
docker ps -a --filter "name=^pia-" --filter "status=exited" --format '{{.Names}}' 2>/dev/null \
    | grep -E '^(pia-test-|pia-keep-test-|pia-keep-renamed-|pia-keep-conflict-|pia-my-test-container)' \
    | xargs -r docker rm -f > /dev/null 2>&1 || true

# --- Argument handling: 'resume' selects the container itself ---
# A name must be rejected, not ignored: silently resuming some other session
# is the worst possible outcome here.
capture_output resume some-name
assert_exit_code 1 "$CAPTURED_EXIT" "resume with a name should fail"
assert_output_contains "does not take a container name" "$CAPTURED_OUTPUT" "resume should reject a name"
assert_output_contains "pia run some-name" "$CAPTURED_OUTPUT" "resume should point at 'run <NAME>'"

capture_output rs some-name
assert_exit_code 1 "$CAPTURED_EXIT" "rs alias should reject a name too"

capture_output resume --help
assert_exit_code 0 "$CAPTURED_EXIT" "resume --help should exit 0"
assert_output_contains "takes no container name" "$CAPTURED_OUTPUT" "resume --help should explain the command"

# --- Empty state: no stopped containers ---
# Only testable when nothing is stopped outside the suite — otherwise
# resume would start a foreign container, so skip instead of interfering.

if foreign_stopped_present; then
    echo -e "  ${YELLOW}SKIP${NC}: stopped pia-* containers exist outside the suite — empty-state resume test skipped"
else
    capture_output resume
    assert_exit_code 0 "$CAPTURED_EXIT" "resume should exit 0"
    assert_output_contains "Resuming the latest stopped agent container" "$CAPTURED_OUTPUT" "resume should show starting message"
    assert_output_contains "No stopped agent containers found" "$CAPTURED_OUTPUT" "resume should report no stopped containers"
fi

# --- Happy path: resume a stopped container ---

# Create a stopped container for testing
TEST_CONTAINER="pia-test-resume-$$"
register_test_container "$TEST_CONTAINER"
docker rm -f "$TEST_CONTAINER" > /dev/null 2>&1 || true
docker run -d --name "$TEST_CONTAINER" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$TEST_CONTAINER" > /dev/null 2>&1

# Verify container is stopped
if docker ps -a --filter "name=^${TEST_CONTAINER}$" --format '{{.Status}}' 2>/dev/null | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: test container is stopped before resume"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: test container should be stopped (got '$(docker ps -a --filter "name=^${TEST_CONTAINER}$" --format "{{.Status}}" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# Run resume — attach_session starts the container detached ('docker start')
# and then 'docker exec pi --continue' fails on alpine (rc 127), which
# deliberately leaves the started container running.
# Deterministic: TEST_CONTAINER was created now, so it is newer than any
# container that existed before this section started.
capture_output resume

# Container should now be running (started before the session attach)
if docker ps --filter "name=^${TEST_CONTAINER}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: resume started the stopped container (container is now running)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: resume should have started the container (state: '$(docker ps -a --filter "name=^${TEST_CONTAINER}$" --format "{{.Status}}" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# --- Multiple stopped containers: resume the one that STOPPED last ---

# Creation order and stop order are deliberately reversed here: the
# newest-created container is stopped FIRST, so a selection based on the
# 'docker ps' listing order (which sorts by creation time) would pick the
# wrong container. The one that stopped last must win.
OLD_CONTAINER="pia-test-older-$$"
register_test_container "$OLD_CONTAINER"
docker rm -f "$OLD_CONTAINER" > /dev/null 2>&1 || true
docker run -d --name "$OLD_CONTAINER" alpine:latest sleep 3600 > /dev/null 2>&1

# Small delay to ensure creation order is detectable
sleep 0.5

# Create a newer container, then stop it first; stop the older one afterwards
NEWER_CONTAINER="pia-test-newer-$$"
register_test_container "$NEWER_CONTAINER"
docker rm -f "$NEWER_CONTAINER" > /dev/null 2>&1 || true
docker run -d --name "$NEWER_CONTAINER" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$NEWER_CONTAINER" > /dev/null 2>&1
sleep 1
docker stop "$OLD_CONTAINER" > /dev/null 2>&1

# Verify both are stopped
if docker ps -a --filter "name=^${NEWER_CONTAINER}$" --format '{{.Status}}' 2>/dev/null | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: newer container is stopped"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: newer container should be stopped"
    FAIL=$((FAIL + 1))
fi

# The independent expectation (stop time, via docker inspect)
if [ "$(resume_target)" = "$OLD_CONTAINER" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: the older container is the most recently stopped one"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: expected '$OLD_CONTAINER' to have stopped last (got '$(resume_target)')"
    FAIL=$((FAIL + 1))
fi

# Run resume — it should pick the container that stopped last
# (OLD_CONTAINER, even though NEWER_CONTAINER is newer-created)
capture_output resume

# The older (last-stopped) container should now be running
if docker ps --filter "name=^${OLD_CONTAINER}$" --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: resume picked the most recently stopped container, not the newest-created one"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: resume should have started the last-stopped container (state: '$(docker ps -a --filter "name=^${OLD_CONTAINER}$" --format "{{.Status}}" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# The newer container should still be stopped
if docker ps -a --filter "name=^${NEWER_CONTAINER}$" --format '{{.Status}}' 2>/dev/null | grep -qi "exited"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: other stopped container remains stopped (resume only picks latest)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: newer container should still be stopped (state: '$(docker ps -a --filter "name=^${NEWER_CONTAINER}$" --format "{{.Status}}" 2>/dev/null)')"
    FAIL=$((FAIL + 1))
fi

# --- Second resume: no more stopped containers ---

# The newer container is still stopped from the multi-container test.
# Remove it so there are no stopped containers left for this test.
docker rm -f "$NEWER_CONTAINER" > /dev/null 2>&1 || true
docker rm -f "$OLD_CONTAINER" > /dev/null 2>&1 || true

# Now no stopped containers should remain — but only assert this when no
# foreign stopped containers exist, otherwise resume would start one.
if foreign_stopped_present; then
    echo -e "  ${YELLOW}SKIP${NC}: stopped pia-* containers exist outside the suite — 'no stopped containers' and 'rs' alias tests skipped"
else
    capture_output resume
    assert_exit_code 0 "$CAPTURED_EXIT" "resume should exit 0 when no stopped containers exist"
    assert_output_contains "No stopped agent containers found" "$CAPTURED_OUTPUT" "resume should report no stopped containers"

    # --- 'rs' alias ---

    capture_output rs
    assert_exit_code 0 "$CAPTURED_EXIT" "rs should exit 0"
    assert_output_contains "No stopped agent containers found" "$CAPTURED_OUTPUT" "rs should report no stopped containers"
fi

# --- Cleanup ---

docker rm -f "$TEST_CONTAINER" "$NEWER_CONTAINER" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 11: The 'keep' command
# =============================================================================
if should_run_section "keep"; then
echo ""
echo -e "${YELLOW}=== SECTION 11: The 'keep' command ===${NC}"

# --- Help ---

capture_output keep --help
assert_exit_code 0 "$CAPTURED_EXIT" "keep --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "keep --help should show usage"

# --- Missing name ---

capture_output keep
assert_exit_code 1 "$CAPTURED_EXIT" "keep without a name should exit 1"
assert_stderr_contains "Please provide a container name" "$CAPTURED_OUTPUT" "keep without name should error"

# --- Missing container ---

capture_output keep test-keep-missing-$$
assert_exit_code 1 "$CAPTURED_EXIT" "keep on missing container should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "keep on missing container should error"

# --- Happy path: keep renames pia-zzz to pia-keep-zzz ---

KEEP_TEST="pia-test-keep-$$"
register_test_container "$KEEP_TEST" "pia-keep-test-keep-$$" "pia-keep-renamed-$$"
docker rm -f "$KEEP_TEST" "pia-keep-test-keep-$$" > /dev/null 2>&1 || true
docker run -d --name "$KEEP_TEST" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$KEEP_TEST" > /dev/null 2>&1

capture_output keep test-keep-$$
assert_exit_code 0 "$CAPTURED_EXIT" "keep should exit 0"

if docker ps -a --filter "name=^pia-keep-test-keep-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-keep-test-keep-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: keep renamed to 'pia-keep-test-keep-$$'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: 'pia-keep-test-keep-$$' should exist after keep"
    FAIL=$((FAIL + 1))
fi

# --- keep is idempotent: already-kept container reports 'already kept' ---

capture_output keep test-keep-$$
assert_exit_code 0 "$CAPTURED_EXIT" "keep on already-kept container should exit 0"
assert_output_contains "already kept" "$CAPTURED_OUTPUT" "keep on already-kept container should report it"

# --- keep with explicit suffix parameter ---

capture_output keep test-keep-$$ renamed-$$
assert_exit_code 0 "$CAPTURED_EXIT" "keep with suffix should exit 0"

if docker ps -a --filter "name=^pia-keep-renamed-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-keep-renamed-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: keep with suffix renamed to 'pia-keep-renamed-$$'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: 'pia-keep-renamed-$$' should exist after keep with suffix"
    FAIL=$((FAIL + 1))
fi

# --- keep works on running containers too ---

KEEP_RUNNING="pia-test-keep-run-$$"
register_test_container "$KEEP_RUNNING" "pia-keep-test-keep-run-$$"
docker rm -f "$KEEP_RUNNING" "pia-keep-test-keep-run-$$" > /dev/null 2>&1 || true
docker run -d --name "$KEEP_RUNNING" alpine:latest sleep 3600 > /dev/null 2>&1

capture_output keep test-keep-run-$$
assert_exit_code 0 "$CAPTURED_EXIT" "keep should work on a running container"

if docker ps --filter "name=^pia-keep-test-keep-run-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-keep-test-keep-run-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: keep renamed a running container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: running container should have been renamed to 'pia-keep-test-keep-run-$$'"
    FAIL=$((FAIL + 1))
fi

# --- keep with a suffix that collides with an existing container: error ---

CONFLICT="pia-keep-conflict-$$"
register_test_container "$CONFLICT"
docker rm -f "$CONFLICT" > /dev/null 2>&1 || true
docker run -d --name "$CONFLICT" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$CONFLICT" > /dev/null 2>&1

capture_output keep renamed-$$ conflict-$$
assert_exit_code 1 "$CAPTURED_EXIT" "keep onto an existing name should exit 1"
assert_stderr_contains "already exists" "$CAPTURED_OUTPUT" "keep collision should report target exists"

# Original kept container must be untouched
if docker ps -a --filter "name=^pia-keep-renamed-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-keep-renamed-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: failed keep left the original container untouched"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: failed keep should not have touched 'pia-keep-renamed-$$'"
    FAIL=$((FAIL + 1))
fi

# --- pia ls lists kept containers ---

capture_output ls
assert_output_contains "pia-keep-renamed-$$" "$CAPTURED_OUTPUT" "pia ls should list kept (pia-keep-*) containers"

# --- Cleanup ---

docker rm -f "pia-keep-test-keep-$$" "pia-keep-renamed-$$" "pia-keep-test-keep-run-$$" "$CONFLICT" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 12: The 'unkeep' command
# =============================================================================
if should_run_section "unkeep"; then
echo ""
echo -e "${YELLOW}=== SECTION 12: The 'unkeep' command ===${NC}"

# --- Help ---

capture_output unkeep --help
assert_exit_code 0 "$CAPTURED_EXIT" "unkeep --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "unkeep --help should show usage"

# --- Missing name ---

capture_output unkeep
assert_exit_code 1 "$CAPTURED_EXIT" "unkeep without a name should exit 1"
assert_stderr_contains "Please provide a container name" "$CAPTURED_OUTPUT" "unkeep without name should error"

# --- Missing container ---

capture_output unkeep test-unkeep-missing-$$
assert_exit_code 1 "$CAPTURED_EXIT" "unkeep on missing container should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "unkeep on missing container should error"

# --- Non-kept container: error ---

UNKEEPPlain="pia-test-unkeep-$$"
docker rm -f "$UNKEEPPlain" > /dev/null 2>&1 || true
docker run -d --name "$UNKEEPPlain" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$UNKEEPPlain" > /dev/null 2>&1

capture_output unkeep test-unkeep-$$
assert_exit_code 1 "$CAPTURED_EXIT" "unkeep on non-kept container should exit 1"
assert_stderr_contains "is not kept" "$CAPTURED_OUTPUT" "unkeep on non-kept container should error"

# --- Happy path: unkeep renames pia-keep-zzz back to pia-zzz ---

docker rename "$UNKEEPPlain" "pia-keep-test-unkeep-$$"

capture_output unkeep test-unkeep-$$
assert_exit_code 0 "$CAPTURED_EXIT" "unkeep should exit 0 (bare name resolves to kept container)"

if docker ps -a --filter "name=^pia-test-unkeep-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-test-unkeep-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: unkeep renamed back to 'pia-test-unkeep-$$'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: 'pia-test-unkeep-$$' should exist after unkeep"
    FAIL=$((FAIL + 1))
fi

# --- unkeep also accepts the full pia-keep-* name ---

docker rename "pia-test-unkeep-$$" "pia-keep-test-unkeep-$$"

capture_output unkeep pia-keep-test-unkeep-$$
assert_exit_code 0 "$CAPTURED_EXIT" "unkeep with full keep name should exit 0"

if docker ps -a --filter "name=^pia-test-unkeep-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-test-unkeep-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: unkeep with full keep name renamed back correctly"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: unkeep with full keep name should rename back"
    FAIL=$((FAIL + 1))
fi

# --- Cleanup ---

docker rm -f "pia-test-unkeep-$$" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 13: The 'rename' command
# =============================================================================
if should_run_section "rename"; then
echo ""
echo -e "${YELLOW}=== SECTION 13: The 'rename' command ===${NC}"

# --- Help ---

capture_output rename --help
assert_exit_code 0 "$CAPTURED_EXIT" "rename --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "rename --help should show usage"

# --- Missing arguments ---

capture_output rename
assert_exit_code 1 "$CAPTURED_EXIT" "rename without args should exit 1"

capture_output rename only-one-$$
assert_exit_code 1 "$CAPTURED_EXIT" "rename with only old name should exit 1"

# --- Missing source ---

capture_output rename test-ren-missing-$$ test-ren-target-$$
assert_exit_code 1 "$CAPTURED_EXIT" "rename with missing source should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "rename with missing source should error"

# --- Happy path: basic rename (bare names get the prefix) ---

REN_SRC="pia-test-ren-$$"
register_test_container "$REN_SRC"
docker rm -f "$REN_SRC" "pia-test-ren-target-$$" > /dev/null 2>&1 || true
docker run -d --name "$REN_SRC" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$REN_SRC" > /dev/null 2>&1

capture_output rename test-ren-$$ test-ren-target-$$
assert_exit_code 0 "$CAPTURED_EXIT" "rename should exit 0"

if docker ps -a --filter "name=^pia-test-ren-target-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-test-ren-target-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: rename produced 'pia-test-ren-target-$$'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: 'pia-test-ren-target-$$' should exist after rename"
    FAIL=$((FAIL + 1))
fi

# --- Renaming into the keep namespace is allowed ---

capture_output rename test-ren-target-$$ pia-keep-ren-$$
assert_exit_code 0 "$CAPTURED_EXIT" "rename into pia-keep-* namespace should exit 0"

if docker ps -a --filter "name=^pia-keep-ren-$$" --format '{{.Names}}' 2>/dev/null | grep -q "pia-keep-ren-$$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: rename into keep namespace produced 'pia-keep-ren-$$'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: 'pia-keep-ren-$$' should exist after rename"
    FAIL=$((FAIL + 1))
fi

# --- Target exists: error ---

capture_output rename keep-ren-$$ test-ren-$$
assert_exit_code 0 "$CAPTURED_EXIT" "rename back should exit 0 (source is free again)"

REN_OTHER="pia-test-ren-other-$$"
register_test_container "$REN_OTHER"
docker rm -f "$REN_OTHER" > /dev/null 2>&1 || true
docker run -d --name "$REN_OTHER" alpine:latest sleep 3600 > /dev/null 2>&1
docker stop "$REN_OTHER" > /dev/null 2>&1

capture_output rename test-ren-$$ test-ren-other-$$
assert_exit_code 1 "$CAPTURED_EXIT" "rename onto an existing name should exit 1"
assert_stderr_contains "already exists" "$CAPTURED_OUTPUT" "rename onto existing name should error"

# --- Same name: no-op ---

capture_output rename test-ren-$$ test-ren-$$
assert_exit_code 0 "$CAPTURED_EXIT" "rename to the same name should exit 0"
assert_output_contains "already has that name" "$CAPTURED_OUTPUT" "same-name rename should report no-op"

# --- Cleanup ---

docker rm -f "pia-test-ren-$$" "pia-test-ren-other-$$" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 14: The 'sh' command
# =============================================================================
if should_run_section "sh"; then
echo ""
echo -e "${YELLOW}=== SECTION 14: The 'sh' command ===${NC}"

capture_output sh --help
assert_exit_code 0 "$CAPTURED_EXIT" "sh --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "sh --help should show usage"
assert_output_contains "interactive bash shell" "$CAPTURED_OUTPUT" "sh --help should describe the shell"

capture_output sh -h
assert_exit_code 0 "$CAPTURED_EXIT" "sh -h should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "sh -h should show usage"

capture_output shell --help
assert_exit_code 0 "$CAPTURED_EXIT" "shell (alias) --help should exit 0"

capture_output sh nonexistent-container-xyz
assert_exit_code 1 "$CAPTURED_EXIT" "sh non-existent should exit 1"
assert_stderr_contains "does not exist" "$CAPTURED_OUTPUT" "sh should report missing container"

capture_output sh test-target-$$ extra-arg
assert_exit_code 1 "$CAPTURED_EXIT" "sh with an extra argument should exit 1"
assert_stderr_contains "Unexpected argument" "$CAPTURED_OUTPUT" "sh should reject extra arguments"

# --- Stopped container: error ---

SH_TEST="pia-test-sh-run-$$"
register_test_container "$SH_TEST"
docker rm -f "$SH_TEST" > /dev/null 2>&1 || true
docker run -d --name "$SH_TEST" -l com.docker.compose.project=pia debian:latest sleep 3600 > /dev/null 2>&1
docker stop "$SH_TEST" > /dev/null 2>&1

if docker container inspect "$SH_TEST" > /dev/null 2>&1; then

capture_output sh "$SH_TEST"
assert_exit_code 1 "$CAPTURED_EXIT" "sh on a stopped container should exit 1"
assert_stderr_contains "is not running" "$CAPTURED_OUTPUT" "sh should say the container is not running"

# --- Happy path: shell in a running container ---

docker start "$SH_TEST" > /dev/null 2>&1

# No TTY here, so pia picks 'docker exec -i'; bash reads EOF from /dev/null and exits.
SH_RC=0
SH_OUT=$(timeout 10 bash "$AGENTS" sh "$SH_TEST" < /dev/null 2>&1) || SH_RC=$?
if [ "$SH_RC" -eq 0 ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: sh opens a shell in the running container (exit=0)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: sh should open a shell (got exit=$SH_RC, output '$SH_OUT')"
    FAIL=$((FAIL + 1))
fi

# --- Auto-select the only running container when NAME is omitted ---

# Deterministic check with a mocked docker: the real-environment variant
# below only runs when exactly one agent container exists, which is rare on
# a dev machine. This shim makes 'sole_running_container' see exactly one
# container regardless of the host's real containers, so the auto-select
# path is exercised on every run.

SH_MOCK="pia-test-sh-mock-$$"
SH_SHIM_DIR="$(mktemp -d)"
cat > "$SH_SHIM_DIR/docker" <<SHIM
#!/bin/bash
case "\$1" in
    ps)   printf 'mockid0001\t$SH_MOCK\trunning\tnow\n' ;;
    container)
        # 'docker container inspect [-f fmt] name' — exist, and be running
        if printf '%s\n' "\$@" | grep -q 'State.Running'; then echo true; fi
        exit 0 ;;
    exec) echo "shim-exec: \$*"; exit 0 ;;
esac
exit 0
SHIM
chmod +x "$SH_SHIM_DIR/docker"

SH_MOCK_RC=0
SH_MOCK_OUT=$(PATH="$SH_SHIM_DIR:$PATH" timeout 10 bash "$AGENTS" sh < /dev/null 2>&1) || SH_MOCK_RC=$?
if [ "$SH_MOCK_RC" -eq 0 ] \
        && echo "$SH_MOCK_OUT" | grep -q "Using the only running container: $SH_MOCK" \
        && echo "$SH_MOCK_OUT" | grep -q "shim-exec: exec.*$SH_MOCK /bin/bash"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: sh without NAME auto-selects the sole running container (mocked)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: sh without NAME should auto-select the sole running container (exit=$SH_MOCK_RC, output '$SH_MOCK_OUT')"
    FAIL=$((FAIL + 1))
fi

# With no containers at all, the shim reports none — auto-select must fail
# with the 'provide a container name' guidance instead of hanging or
# guessing.
cat > "$SH_SHIM_DIR/docker" <<SHIM
#!/bin/bash
case "\$1" in
    ps) exit 0 ;;
esac
exit 1
SHIM
chmod +x "$SH_SHIM_DIR/docker"

SH_NONE_RC=0
SH_NONE_OUT=$(PATH="$SH_SHIM_DIR:$PATH" timeout 10 bash "$AGENTS" sh < /dev/null 2>&1) || SH_NONE_RC=$?
if [ "$SH_NONE_RC" -eq 1 ] && echo "$SH_NONE_OUT" | grep -q "Please provide a container name"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: sh without NAME and no running containers asks for a name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: sh with no containers should ask for a name (exit=$SH_NONE_RC, output '$SH_NONE_OUT')"
    FAIL=$((FAIL + 1))
fi

rm -rf "$SH_SHIM_DIR"

# Real-environment integration check: only meaningful when exactly one
# agent container is running; skipped otherwise (the mocked test above
# guarantees the path stays covered).
RUNNING_PIA=$({ docker ps --filter "name=^pia-" --format '{{.Names}}' 2>/dev/null
    docker ps --filter "label=com.docker.compose.project=pia" --format '{{.Names}}' 2>/dev/null; } | sort -u | grep -c . || true)
if [ "$RUNNING_PIA" -eq 1 ]; then
    SH_AUTO_RC=0
    SH_AUTO_OUT=$(timeout 10 bash "$AGENTS" sh < /dev/null 2>&1) || SH_AUTO_RC=$?
    if [ "$SH_AUTO_RC" -eq 0 ] && echo "$SH_AUTO_OUT" | grep -q "$SH_TEST"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: sh without NAME uses the only running container"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: sh without NAME should use the only running container (exit=$SH_AUTO_RC, output '$SH_AUTO_OUT')"
        FAIL=$((FAIL + 1))
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}: sh without NAME (expected exactly 1 running pia container, found $RUNNING_PIA)"
fi

else
    echo -e "  ${YELLOW}SKIP${NC}: docker-based 'sh' checks (could not create the test container)"
fi

docker rm -f "$SH_TEST" > /dev/null 2>&1 || true
fi

# =============================================================================
# SECTION 15: The 'monitor' command — argument parsing (general)
# =============================================================================
if should_run_section "general"; then
echo ""
echo -e "${YELLOW}=== SECTION 15: The 'monitor' command (parsing) ===${NC}"

capture_output monitor --help
assert_exit_code 0 "$CAPTURED_EXIT" "monitor --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "monitor --help should show usage"
assert_output_contains "--interval" "$CAPTURED_OUTPUT" "monitor --help should document --interval"
assert_output_contains "capture chunk (default: 5)" "$CAPTURED_OUTPUT" "monitor --help should say --interval also sets the raw chunk"
assert_output_contains "--raw" "$CAPTURED_OUTPUT" "monitor --help should document --raw"
assert_output_contains "stops the capture inside" "$CAPTURED_OUTPUT" "monitor --help should promise to clean the capture up"

capture_output monitor -h
assert_exit_code 0 "$CAPTURED_EXIT" "monitor -h should exit 0"

capture_output monitor -i
assert_exit_code 1 "$CAPTURED_EXIT" "monitor -i without a value should exit 1"
assert_output_contains "requires a value" "$CAPTURED_OUTPUT" "monitor -i without value should say so"

capture_output monitor -i abc
assert_exit_code 1 "$CAPTURED_EXIT" "monitor -i abc should exit 1"
assert_output_contains "whole number" "$CAPTURED_OUTPUT" "monitor -i abc should explain the format"

capture_output monitor -i 0
assert_exit_code 1 "$CAPTURED_EXIT" "monitor -i 0 should exit 1 (interval must be >= 1)"

capture_output monitor one two
assert_exit_code 1 "$CAPTURED_EXIT" "monitor with two names should exit 1"
assert_output_contains "Unexpected argument" "$CAPTURED_OUTPUT" "monitor should reject a second name"
fi

# =============================================================================
# SECTION 16: The 'monitor' command — container handling (mocked docker)
# =============================================================================
if should_run_section "monitor"; then
echo ""
echo -e "${YELLOW}=== SECTION 16: The 'monitor' command (mocked docker) ===${NC}"


MON_NAME="pia-test-monmock"
# Fixed name, not mktemp: 'run-tests.sh' removes it on exit (including Ctrl-C)
# along with the other test temp files, so an aborted run leaves nothing behind.
MON_SHIM_DIR="/tmp/pia-test-monshim-$$"
rm -rf "$MON_SHIM_DIR"; mkdir -p "$MON_SHIM_DIR"

# One mock 'docker' for every scenario in this section. Its behaviour comes from
# files that 'mon_setup' writes before each run, so the scenarios read as data
# rather than as five near-identical shims:
#   state    what 'docker container inspect' reports: 'running', 'exited',
#            'missing', or 'running:N' to report running only for the first N
#            checks — that is how a container disappearing mid-monitor is faked
#   helper   'yes' if the image has the 'pia-monitor' helper, 'no' if it predates it
#   sampler  exit code of the 'pia-monitor ...' exec (0 = healthy cycle)
#   stubborn 'yes' if a helper survives 'pkill' (models a hand-started one that
#            ignores signals); 'pkill' then reports 0 = "killed something" forever,
#            while 'no' reports the real 1 = "no process matched"
#   calls    every 'docker exec' argument list, one per line, so a test can assert
#            on what actually ran inside the container, not just on the message
cat > "$MON_SHIM_DIR/docker" <<SHIM
#!/bin/bash
mon_read() { cat "$MON_SHIM_DIR/\$1" 2>/dev/null || echo ""; }
case "\$1" in
    ps)
        if [ "\$(mon_read state)" = "exited" ]; then
            printf 'mockid1\t$MON_NAME\texited\tnow\n'
        else
            printf 'mockid1\t$MON_NAME\trunning\tnow\n'
        fi
        ;;
    container)
        state="\$(mon_read state)"
        case "\$state" in (missing) exit 1 ;; esac
        if printf '%s\n' "\$@" | grep -q 'State.Running'; then
            case "\$state" in
                exited) ;;
                running:*)
                    # Running for the first N checks, gone afterwards.
                    n="\${state#running:}"
                    c=\$(cat "$MON_SHIM_DIR/checks" 2>/dev/null || echo 0)
                    echo \$((c + 1)) > "$MON_SHIM_DIR/checks"
                    [ "\$c" -lt "\$n" ] && echo true ;;
                *) echo true ;;
            esac
        fi
        exit 0 ;;
    exec)
        printf '%s\n' "\$*" >> "$MON_SHIM_DIR/calls"
        case "\$*" in
            *"command -v pia-monitor"*)
                [ "\$(mon_read helper)" = "yes" ] || exit 1
                exit 0 ;;
            *"pia-monitor "*)
                echo "shim-sample: cpu 1.0%"
                exit "\$(mon_read sampler)" ;;
            *"pkill "*)
                # Real pkill answers 1 ('no process matched') once the helper is
                # gone, which is the normal case here because mock execs finish
                # immediately. stubborn=yes models a helper that never dies.
                [ "\$(mon_read stubborn)" = "yes" ] && exit 0
                exit 1 ;;
        esac
        exit 0 ;;
esac
exit 0
SHIM
chmod +x "$MON_SHIM_DIR/docker"

# mon_setup STATE HELPER SAMPLER [STUBBORN] — configure the mock for one scenario.
mon_setup() {
    printf '%s' "$1" > "$MON_SHIM_DIR/state"
    printf '%s' "$2" > "$MON_SHIM_DIR/helper"
    printf '%s' "$3" > "$MON_SHIM_DIR/sampler"
    printf '%s' "${4:-no}" > "$MON_SHIM_DIR/stubborn"
    : > "$MON_SHIM_DIR/calls"
    rm -f "$MON_SHIM_DIR/checks"
}

# mon_run [ARGS...] — run 'monitor' against the mock; sets MON_RC and MON_OUT.
mon_run() {
    MON_RC=0
    MON_OUT=$(PATH="$MON_SHIM_DIR:$PATH" timeout 5 bash "$AGENTS" monitor "$@" < /dev/null 2>&1) || MON_RC=$?
}

# mon_assert EXIT_CODE PHRASE DESCRIPTION — the two checks every scenario makes.
mon_assert() {
    local want_rc="$1" want_text="$2" description="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$MON_RC" -eq "$want_rc" ] && echo "$MON_OUT" | grep -qF -- "$want_text"; then
        echo -e "  ${GREEN}PASS${NC}: $description (exit=$MON_RC)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (exit=$MON_RC wanted $want_rc, output '$MON_OUT')"
        FAIL=$((FAIL + 1))
    fi
}

# mon_assert_calls PATTERN DESCRIPTION — assert on the recorded 'docker exec' calls.
mon_assert_calls() {
    local pattern="$1" description="$2"
    TOTAL=$((TOTAL + 1))
    if grep -Eq -- "$pattern" "$MON_SHIM_DIR/calls" 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (calls were: $(tr '\n' ' ' < "$MON_SHIM_DIR/calls" 2>/dev/null))"
        FAIL=$((FAIL + 1))
    fi
}

# mon_assert_no_calls PATTERN DESCRIPTION — the calls that must NOT have been made.
mon_assert_no_calls() {
    local pattern="$1" description="$2"
    TOTAL=$((TOTAL + 1))
    if grep -Eq -- "$pattern" "$MON_SHIM_DIR/calls" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC}: $description (calls were: $(tr '\n' ' ' < "$MON_SHIM_DIR/calls" 2>/dev/null))"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    fi
}

# --- container resolution ---------------------------------------------------

# An image built before the monitor existed has no helper inside; the user needs
# to be told how to recover, not just that something failed.
mon_setup running no 0
mon_run test-monmock
mon_assert 1 "no 'pia-monitor' helper" "monitor on an image without the helper explains how to rebuild"

# 'monitor' needs a running container: an existing but stopped one is refused.
mon_setup exited yes 0
mon_run test-monmock
mon_assert 1 "is not running" "monitor on a stopped container asks to start it"

# A name that matches no container at all.
mon_setup missing yes 0
mon_run test-monmock
mon_assert 1 "does not exist" "monitor on a missing container says it does not exist"

# --- what runs inside the container ----------------------------------------

# Cycled mode: one bounded 'pia-monitor cycle <interval>' per pass, and the
# container is reported running twice (pre-flight + first pass) so the loop must
# end by itself on the next check instead of spinning or erroring forever.
mon_setup running:2 yes 0
mon_run test-monmock -i 1
mon_assert 0 "shim-sample" "monitor prints the samples the helper produced"
mon_assert_calls "exec $MON_NAME pia-monitor cycle 1" "monitor runs one bounded 'pia-monitor cycle <interval>' per pass"
mon_assert 0 "no longer running" "monitor ends by itself when the container stops"

# Nothing may keep capturing inside the container once we stop watching it —
# 'pia monitor' stops the helper and its tshark on the way out.
mon_assert_calls "pkill .*pia-monitor" "monitor stops the in-container sampler when it ends"

# ... by naming ONLY its own helper. Stopping the capture is the helper's own
# signal handler's job; a pattern that also named tshark would kill a tshark the
# agent runs for its own work.
mon_assert_no_calls "pkill .*tshark" "monitor's stop pattern names the helper, not tshark"

# ... and only its own MODES. The long-running 'pia-monitor log' destination
# logger (the history behind 'pia urls') must survive every monitor.
mon_assert_calls "pkill -f pia-monitor [(]cycle[|]raw[)]" "monitor's stop pattern is narrowed to the monitor modes"
mon_assert_no_calls "pkill -f pia-monitor$" "monitor never pkills pia-monitor unconditionally (the URL logger would die)"

# Long option and options before the name are accepted like everywhere else.
mon_setup running:2 yes 0
mon_run --interval 1 test-monmock
mon_assert 0 "shim-sample" "monitor accepts --interval before the name"
mon_assert_calls "exec $MON_NAME pia-monitor cycle 1" "--interval reaches the helper"

# A failing sampler (missing CAP_NET_RAW, vanished interface, ...) already
# explained itself inside the container; the loop must stop and fail, not print
# empty cycles as if the container were merely idle. The container keeps
# answering 'running' here, so the failure cannot be blamed on the container.
mon_setup running:5 yes 2
mon_run test-monmock -i 1
mon_assert 1 "sampler exited with code 2" "monitor stops and fails when the sampler exits non-zero"

# Raw mode: streamed destinations, no resource summary — and bounded chunks, so
# the loop can notice a gone container (one endless exec would hang forever).
# Same 'running' twice, so this asserts both the exec form and the loop exit.
mon_setup running:2 yes 0
mon_run --raw
mon_assert 0 "Using the only running container: $MON_NAME" "monitor --raw picks the sole running container"
mon_assert_calls "exec $MON_NAME pia-monitor raw [0-9]+" "monitor --raw runs a bounded 'pia-monitor raw <chunk>'"
mon_assert 0 "no longer running" "monitor --raw ends by itself when the container stops"
mon_assert_calls "pkill .*pia-monitor" "monitor --raw stops the in-container sampler when it ends"

# '-i' means the same thing in both modes: with --raw it is the chunk length, so
# the sample interval is never silently ignored (the chunk default of 5s only
# applies when the option is absent).
mon_setup running:2 yes 0
mon_run --raw -i 2
mon_assert_calls "exec $MON_NAME pia-monitor raw 2" "--interval sets the length of a --raw chunk"
mon_assert_no_calls "exec $MON_NAME pia-monitor raw 5" "--raw does not ignore --interval in favour of its default chunk"

mon_setup running:2 yes 0
mon_run --raw
mon_assert_calls "exec $MON_NAME pia-monitor raw 5" "--raw without --interval uses the 5s default chunk"

# Stopping is confirmed, not assumed: 'pkill' returns as soon as the signal is
# delivered, so a helper that never dies must be reported instead of silently
# treated as gone — the whole promise is that nothing keeps capturing after
# 'pia monitor' returns.
mon_setup running:2 yes 0 yes
mon_run test-monmock -i 1
mon_assert 0 "still running" "monitor reports a helper that survives the stop signal"

rm -rf "$MON_SHIM_DIR"
fi

# =============================================================================
# SECTION 17: The 'monitor' command (real container)
# =============================================================================
if should_run_section "monitor"; then
echo ""
echo -e "${YELLOW}=== SECTION 17: The 'monitor' command (real container) ===${NC}"

# The mock above cannot prove that the capture started inside the container is
# really stopped with us, nor that a raw monitor notices a container that went
# away — both are properties of the running pair. These two checks need the
# 'pia' image built with tshark and the helper, and a helper that stops on its
# own after a duration (older images capture until killed, which is exactly what
# is being tested, so they cannot test it). Elsewhere the section reports a skip
# rather than a failure, because the CLI behaviour is covered above.
MON_LIVE="pia-test-mon-live-$$"
MON_LIVE_DIR="/tmp/pia-test-monlive-$$"
register_test_container "$MON_LIVE"
rm -rf "$MON_LIVE_DIR"; mkdir -p "$MON_LIVE_DIR"
docker rm -f "$MON_LIVE" > /dev/null 2>&1 || true

if docker run -d --name "$MON_LIVE" -l com.docker.compose.project=pia pia sleep infinity > /dev/null 2>&1 \
        && docker exec "$MON_LIVE" sh -c 'command -v pia-monitor > /dev/null 2>&1 && command -v tshark > /dev/null 2>&1' \
        && timeout 4 docker exec "$MON_LIVE" pia-monitor raw 1 > /dev/null 2>&1; then

# sampler_left — is anything still capturing inside the container? pgrep is
# called directly, not through 'sh -c': a shell whose command line contains the
# pattern would match itself.
mon_live_sampler_left() {
    docker exec "$MON_LIVE" pgrep -f 'pia-monitor|tshark -Q' > /dev/null 2>&1
}

# mon_live_zombies — how many killed-but-unreaped captures are left behind.
# pgrep cannot see them (a zombie has no command line), so this reads 'ps'.
# PID 1 of the agent image is 'sleep infinity', which never reaps: an
# interrupted helper that did not wait for its tshark would leave one of these
# per interrupted monitor, inflating the 'pids' column of every later sample.
mon_live_zombies() {
    docker exec "$MON_LIVE" ps -eo stat=,comm= | awk '$1 ~ /^Z/ && $2 ~ /tshark/ { n++ } END { print n + 0 }'
}

# mon_live_stop PID — stop a running monitor and wait for it to be gone.
# SIGTERM, not SIGINT: a background job of a non-interactive shell inherits
# SIGINT ignored, and an ignored signal cannot be trapped — which is why this
# uses the TERM handler (the same one Ctrl-C reaches, a foreground monitor
# having SIGINT unignored). Its handler cannot run before the in-flight
# 'docker exec' returns, so waiting for the process is what "it stopped" means;
# the chunk length bounds that, so the patience here is two default chunks plus
# docker overhead — long enough to be a real deadline, short enough that a
# regression shows up as a failure of this section rather than a stalled run.
# Exit is read from 'ps', not 'kill -0', because an exited child that is not
# reaped yet still answers 'kill -0'.
mon_live_stop() {
    local pid="$1" i stat
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 24); do
        stat="$(ps -o stat= -p "$pid" 2>/dev/null)"
        case "$stat" in ('' | Z*) return 0 ;; esac
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null || true
    return 1
}

# --- stopping the monitor leaves no capture running inside the container ----

bash "$AGENTS" monitor "$MON_LIVE" --raw < /dev/null > "$MON_LIVE_DIR/raw.log" 2>&1 &
MON_LIVE_PID=$!
sleep 3
if mon_live_stop "$MON_LIVE_PID"; then mon_live_stopped=ok; else mon_live_stopped=hang; fi
wait "$MON_LIVE_PID" 2>/dev/null || true

TOTAL=$((TOTAL + 1))
if [ "$mon_live_stopped" != "ok" ]; then
    echo -e "  ${RED}FAIL${NC}: a stopped monitor should exit promptly (it hung)"
    FAIL=$((FAIL + 1))
elif mon_live_sampler_left; then
    echo -e "  ${RED}FAIL${NC}: a stopped monitor should leave no capture running (inside the container: pgrep -f 'pia-monitor|tshark -Q')"
    FAIL=$((FAIL + 1))
else
    echo -e "  ${GREEN}PASS${NC}: a stopped monitor stops the capture it started"
    PASS=$((PASS + 1))
fi

# --- the helper's own stop path reaps the capture --------------------------

# This is exactly what 'pia monitor' does on its way out ('pkill -f
# pia-monitor'), driven directly so no timing can hide a regression: without
# the reap in the helper's signal handler, every interrupted capture leaves one
# zombie tshark behind (PID 1 of this image is 'sleep infinity', which never
# reaps), and they accumulate for the life of the container.
docker exec -d "$MON_LIVE" pia-monitor raw 20 > /dev/null 2>&1
sleep 2
docker exec "$MON_LIVE" pkill -f 'pia-monitor' > /dev/null 2>&1
sleep 1

TOTAL=$((TOTAL + 1))
mon_live_zombies_now="$(mon_live_zombies)"
if mon_live_sampler_left; then
    echo -e "  ${RED}FAIL${NC}: a killed helper should stop the capture it owns"
    FAIL=$((FAIL + 1))
elif [ "$mon_live_zombies_now" -ne 0 ]; then
    echo -e "  ${RED}FAIL${NC}: a killed helper should reap its tshark (${mon_live_zombies_now} zombie(s) left; they inflate the 'pids' column)"
    FAIL=$((FAIL + 1))
else
    echo -e "  ${GREEN}PASS${NC}: a killed helper stops and reaps its capture (no zombie left)"
    PASS=$((PASS + 1))
fi

# --- the monitor ends by itself when the container stops ---------------------

# Raw mode used to be one endless 'docker exec', which simply hung here. It now
# runs in chunks, so the loop notices the container is gone within a chunk.
bash "$AGENTS" monitor "$MON_LIVE" --raw < /dev/null > "$MON_LIVE_DIR/gone.log" 2>&1 &
MON_LIVE_PID=$!
sleep 2
docker stop "$MON_LIVE" > /dev/null 2>&1

# The monitor notices within one chunk (5s by default), so two chunks of
# patience is a real deadline rather than an open-ended wait.
for _ in $(seq 1 24); do
    kill -0 "$MON_LIVE_PID" 2>/dev/null || break
    sleep 0.5
done

if kill -0 "$MON_LIVE_PID" 2>/dev/null; then
    kill -KILL "$MON_LIVE_PID" 2>/dev/null || true
    wait "$MON_LIVE_PID" 2>/dev/null || true
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: monitor --raw should end when its container stops (it hung; output: $(tr '\n' ' ' < "$MON_LIVE_DIR/gone.log"))"
    FAIL=$((FAIL + 1))
else
    wait "$MON_LIVE_PID" 2>/dev/null || true
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: monitor --raw ends by itself when its container stops"
    PASS=$((PASS + 1))
fi

# And it says so, instead of failing silently.
TOTAL=$((TOTAL + 1))
if grep -qE "no longer running|sampler exited" "$MON_LIVE_DIR/gone.log"; then
    echo -e "  ${GREEN}PASS${NC}: monitor --raw reports why it ended"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: monitor --raw should say the container is gone (output: $(tr '\n' ' ' < "$MON_LIVE_DIR/gone.log"))"
    FAIL=$((FAIL + 1))
fi

else
    echo -e "  ${YELLOW}SKIP${NC}: live monitor checks need a 'pia' image built with tshark and pia-monitor"
    echo -e "           (a helper that stops after a duration — rebuild with bash scripts/build-docker.sh)"
fi

docker rm -f "$MON_LIVE" > /dev/null 2>&1 || true
rm -rf "$MON_LIVE_DIR"
fi

# =============================================================================
# SECTION 18: The 'urls' command — argument parsing (general)
# =============================================================================
if should_run_section "urls"; then
echo ""
echo -e "${YELLOW}=== SECTION 18: The 'urls' command (parsing) ===${NC}"

capture_output urls --help
assert_exit_code 0 "$CAPTURED_EXIT" "urls --help should exit 0"
assert_output_contains "Usage:" "$CAPTURED_OUTPUT" "urls --help should show usage"
assert_output_contains "--all" "$CAPTURED_OUTPUT" "urls --help should document --all"
assert_output_contains "since it was created" "$CAPTURED_OUTPUT" "urls --help should promise the full history"

capture_output urls -h
assert_exit_code 0 "$CAPTURED_EXIT" "urls -h should exit 0"

capture_output urls one two
assert_exit_code 1 "$CAPTURED_EXIT" "urls with two names should exit 1"
assert_output_contains "Unexpected argument" "$CAPTURED_OUTPUT" "urls should reject a second name"
fi

# =============================================================================
# SECTION 19: The 'urls' command — container handling (mocked docker)
# =============================================================================
if should_run_section "urls"; then
echo ""
echo -e "${YELLOW}=== SECTION 19: The 'urls' command (mocked docker) ===${NC}"

URL_NAME="pia-test-urlmock"
URL_SHIM_DIR="/tmp/pia-test-urlshim-$$"
rm -rf "$URL_SHIM_DIR"; mkdir -p "$URL_SHIM_DIR"

cat > "$URL_SHIM_DIR/docker" <<SHIM
#!/bin/bash
url_read() { cat "$URL_SHIM_DIR/\$1" 2>/dev/null || echo ""; }
case "\$1" in
    ps)
        printf 'mockid1\t$URL_NAME\trunning\tnow\n' ;;
    container)
        state="\$(url_read state)"
        case "\$state" in (missing) exit 1 ;; esac
        if printf '%s\n' "\$@" | grep -q 'State.Running'; then
            [ "\$state" = "running" ] && echo true
        fi
        exit 0 ;;
    exec)
        printf '%s\n' "\$*" >> "$URL_SHIM_DIR/calls"
        case "\$*" in
            *"command -v pia-monitor"*)
                [ "\$(url_read helper)" = "yes" ] || exit 1
                exit 0 ;;
            *"pia-monitor urls all"*)
                echo "shim-urls-all" ;;
            *"pia-monitor urls"*)
                echo "shim-urls-summary" ;;
        esac
        exit 0 ;;
esac
exit 0
SHIM
chmod +x "$URL_SHIM_DIR/docker"

# url_setup STATE HELPER — configure the mock for one scenario.
url_setup() {
    printf '%s' "$1" > "$URL_SHIM_DIR/state"
    printf '%s' "$2" > "$URL_SHIM_DIR/helper"
    : > "$URL_SHIM_DIR/calls"
}

# url_run [ARGS...] — run 'urls' against the mock; sets URL_RC and URL_OUT.
url_run() {
    URL_RC=0
    URL_OUT=$(PATH="$URL_SHIM_DIR:$PATH" timeout 5 bash "$AGENTS" urls "$@" < /dev/null 2>&1) || URL_RC=$?
}

# url_assert EXIT_CODE PHRASE DESCRIPTION
url_assert() {
    local want_rc="$1" want_text="$2" description="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$URL_RC" -eq "$want_rc" ] && echo "$URL_OUT" | grep -qF -- "$want_text"; then
        echo -e "  ${GREEN}PASS${NC}: $description (exit=$URL_RC)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (exit=$URL_RC wanted $want_rc, output '$URL_OUT')"
        FAIL=$((FAIL + 1))
    fi
}

# url_assert_calls PATTERN DESCRIPTION
url_assert_calls() {
    local pattern="$1" description="$2"
    TOTAL=$((TOTAL + 1))
    if grep -Eq -- "$pattern" "$URL_SHIM_DIR/calls" 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (calls were: $(tr '\n' ' ' < "$URL_SHIM_DIR/calls" 2>/dev/null))"
        FAIL=$((FAIL + 1))
    fi
}

url_setup missing yes
url_run test-urlmock
url_assert 1 "does not exist" "urls on a missing container says it does not exist"

url_setup exited yes
url_run test-urlmock
url_assert 1 "is not running" "urls on a stopped container asks to start it"

url_setup running no
url_run test-urlmock
url_assert 1 "no 'pia-monitor' helper" "urls on an image without the helper explains how to rebuild"

url_setup running yes
url_run test-urlmock
url_assert 0 "shim-urls-summary" "urls prints what the in-container helper produced"
url_assert_calls "exec $URL_NAME pia-monitor urls$" "urls runs 'pia-monitor urls' (aggregated) in the container"

url_setup running yes
url_run --all
url_assert 0 "Using the only running container: $URL_NAME" "urls picks the sole running container without a name"
url_assert_calls "exec $URL_NAME pia-monitor urls all" "urls --all runs 'pia-monitor urls all'"

url_setup running yes
url_run --all test-urlmock
url_assert_calls "exec $URL_NAME pia-monitor urls all" "urls accepts --all before the name"

rm -rf "$URL_SHIM_DIR"
fi

# =============================================================================
# SECTION 20: The 'urls' command (real container)
# =============================================================================
if should_run_section "urls"; then
echo ""
echo -e "${YELLOW}=== SECTION 20: The 'urls' command (real container) ===${NC}"

# The entrypoint of an IDLE container (no command) starts the destination
# logger; a container run with a command must not get one. This section needs
# the 'pia' image built with tshark and the current entrypoint — elsewhere it
# reports a skip.
URL_LIVE="pia-test-urllive-$$"
register_test_container "$URL_LIVE"
docker rm -f "$URL_LIVE" > /dev/null 2>&1 || true

if docker run -d --name "$URL_LIVE" -l com.docker.compose.project=pia pia > /dev/null 2>&1 \
        && docker exec "$URL_LIVE" sh -c 'command -v pia-monitor > /dev/null 2>&1 && command -v tshark > /dev/null 2>&1'; then

# --- the entrypoint starts the logger, and the log file appears ------------
url_live_logger=missing
for _ in $(seq 1 20); do
    if docker exec "$URL_LIVE" pgrep -f 'pia-monitor log' > /dev/null 2>&1; then url_live_logger=ok; break; fi
    sleep 0.5
done
TOTAL=$((TOTAL + 1))
if [ "$url_live_logger" = ok ]; then
    echo -e "  ${GREEN}PASS${NC}: an idle container starts the destination logger by itself"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: the entrypoint should start 'pia-monitor log' (old image? rebuild)"
    FAIL=$((FAIL + 1))
fi

# --- a real request shows up in 'pia urls' ---------------------------------
# HTTPS: only the SNI hostname is visible, and that is what must be listed.
# The logger's tshark needs a moment after container start to attach to the
# interface, and requests inside that window are legitimately lost — so
# repeat the request until one lands in the log, then assert on the history.
# Stopping at the first captured request also keeps the hit count at x1.
url_live_requested=no
for _ in $(seq 1 10); do
    if docker exec "$URL_LIVE" sh -c 'curl -sI --max-time 10 https://pi.dev > /dev/null 2>&1 || wget -q --timeout=10 -O /dev/null https://pi.dev 2>/dev/null'; then
        url_live_requested=yes
    fi
    sleep 1
    docker exec "$URL_LIVE" grep -q 'pi\.dev' /var/log/pia-urls.log 2>/dev/null && break
done

TOTAL=$((TOTAL + 1))
URL_LIVE_OUT="$(bash "$AGENTS" urls "$URL_LIVE" < /dev/null 2>&1)"; URL_LIVE_RC=$?
if [ "$url_live_requested" != yes ]; then
    echo -e "  ${YELLOW}SKIP${NC}: live urls check needs outbound HTTPS from the container"
elif [ "$URL_LIVE_RC" -eq 0 ] && echo "$URL_LIVE_OUT" | grep -qE '[0-9]+ request\(s\) to [0-9]+ destination\(s\) since the container was created'; then
    echo -e "  ${GREEN}PASS${NC}: pia urls reports the request history with a summary header"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: pia urls should print the history (exit=$URL_LIVE_RC, output: $(echo "$URL_LIVE_OUT" | tr '\n' ' '))"
    FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
URL_LIVE_ALL="$(bash "$AGENTS" urls "$URL_LIVE" --all < /dev/null 2>&1)"
if [ "$url_live_requested" != yes ]; then
    echo -e "  ${YELLOW}SKIP${NC}: live urls --all check needs outbound HTTPS from the container"
elif echo "$URL_LIVE_ALL" | grep -q "pi.dev" && echo "$URL_LIVE_OUT" | grep -qE "x1 +TLS +pi\.dev"; then
    echo -e "  ${GREEN}PASS${NC}: the HTTPS destination (SNI) appears in both --all and the summary"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: the requested HTTPS destination should be logged (all: $(echo "$URL_LIVE_ALL" | tr '\n' ' ') | summary: $(echo "$URL_LIVE_OUT" | tr '\n' ' '))"
    FAIL=$((FAIL + 1))
fi

docker rm -f "$URL_LIVE" > /dev/null 2>&1 || true
else
    echo -e "  ${YELLOW}SKIP${NC}: live urls checks need a 'pia' image built with tshark and the URL-logging entrypoint"
    echo -e "           (rebuild with bash scripts/build-docker.sh)"
    docker rm -f "$URL_LIVE" > /dev/null 2>&1 || true
fi
fi
