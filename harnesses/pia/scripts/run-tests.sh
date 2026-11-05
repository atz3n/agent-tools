#!/bin/bash

# Main test runner for pia.sh
# Sources individual test modules and runs them in order.
#
# Usage:
#   ./run-tests.sh                    # Run all tests
#   ./run-tests.sh run stop           # Run only run and stop tests
#   ./run-tests.sh clean resume       # Run only clean and resume tests

PASS=0
FAIL=0
TOTAL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$SCRIPT_DIR/pia.sh"

# ─── Assertion helpers ───────────────────────────────────────────────

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" -eq "$expected" ]; then
        echo -e "  ${GREEN}PASS${NC}: $description (exit=$actual)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (expected exit=$expected, got exit=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_contains() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -qF -- "$expected"; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (output does not contain '$expected')"
        echo "       Output: $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_not_contains() {
    local not_expected="$1"
    local actual="$2"
    local description="$3"
    TOTAL=$((TOTAL + 1))
    if ! echo "$actual" | grep -qF -- "$not_expected"; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (output should NOT contain '$not_expected')"
        FAIL=$((FAIL + 1))
    fi
}

assert_stderr_contains() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -qF -- "$expected"; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (stderr does not contain '$expected')"
        echo "       Stderr: $actual"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: run script and capture both output and exit code
# Redirects stdin from /dev/null so docker run -it fails immediately
# instead of hanging waiting for a TTY. Also uses timeout as a safety net.
CAPTURE_TIMEOUT=3
capture_output() {
    local tmpout
    tmpout=$(mktemp)
    timeout "$CAPTURE_TIMEOUT" bash "$AGENTS" "$@" < /dev/null >"$tmpout" 2>&1
    CAPTURED_EXIT=$?
    CAPTURED_OUTPUT=$(cat "$tmpout")
    rm -f "$tmpout"
    # Detect timeout (exit 124) and report it
    if [ "$CAPTURED_EXIT" -eq 124 ]; then
        echo -e "  ${YELLOW}TIMEOUT${NC}: Command exceeded ${CAPTURE_TIMEOUT}s" >&2
    fi
}

# Helper: extract just the name field from extract_name_and_options output
# Output format is: NAME|HELP_REQUESTED|INVALID_OPTION|MOUNT_DIR|SSH_FLAG
extract_name_only() {
    echo "$1" | cut -d'|' -f1
}

# ─── Command filter ──────────────────────────────────────────────────
# Usage: ./run-tests.sh [command1 [command2 ...]]
# No arguments = run all tests. Arguments filter to only those commands.

FILTERED_COMMANDS=()
for arg in "$@"; do
    FILTERED_COMMANDS+=("$arg")
done

# Returns 0 (true) if a section should run based on the command filter.
# $1 = command name this section tests (or "general" for non-command-specific tests)
should_run_section() {
    local section_cmd="$1"

    # No filter means run all sections
    if [ ${#FILTERED_COMMANDS[@]} -eq 0 ]; then
        return 0
    fi

    # "general" sections always run (they test CLI parsing, not Docker)
    if [ "$section_cmd" = "general" ]; then
        return 0
    fi

    # Check if any filtered command matches
    for cmd in "${FILTERED_COMMANDS[@]}"; do
        if [ "$cmd" = "$section_cmd" ]; then
            return 0
        fi
    done

    return 1
}

# ─── Cleanup ─────────────────────────────────────────────────────────

# Registry of container names created by tests. Every test that creates (or
# tries to create) a container registers its name here BEFORE the call, so
# cleanup knows exactly which containers are test containers — no name-
# pattern guessing required. Names are registered even if the creation later
# fails or times out: a registered-but-missing container is a no-op to rm.
TEST_CONTAINERS_FILE="/tmp/pia-test-containers-$$"
: > "$TEST_CONTAINERS_FILE"

register_test_container() {
    local n
    for n in "$@"; do
        [ -n "$n" ] && printf '%s\n' "$n" >> "$TEST_CONTAINERS_FILE"
    done
}

# Safety net: remove test containers left behind by failed, timed-out, or
# interrupted tests. Sections clean up inline as they go; this trap runs on
# exit (including Ctrl-C and early failures) so no test container ever
# survives a run. The registry file is authoritative; the name-pattern sweep
# remains only as a last-resort net for containers whose registration was
# missed. Only test name patterns are matched — real containers
# (pia-<name>, pia-keep-<name>) are never touched.
cleanup_test_containers() {
    local names
    names=$(cat "$TEST_CONTAINERS_FILE" 2>/dev/null | sort -u || true)
    names="$names
$(docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -E '^(pia-test-|pia-keep-test-|pia-keep-renamed-|pia-keep-conflict-|pia-my-test-container|not-pia-container)' \
    || true)"
    names=$(printf '%s\n' "$names" | grep -v '^$' | sort -u || true)
    if [ -n "$names" ]; then
        echo ""
        echo "Cleaning up leftover test containers:"
        echo "$names" | sed 's/^/  /'
        echo "$names" | xargs -r docker rm -f > /dev/null 2>&1 || true
    fi
    # Temp files created by tests (modules are sourced, so $$ matches the same shell)
    rm -rf "/tmp/pia-test-sshsock-$$" "/tmp/test-build-docker-args-$$" \
           "/tmp/pia-test-monshim-$$" "/tmp/pia-test-monlive-$$" \
           "/tmp/pia-test-urlshim-$$" "$TEST_CONTAINERS_FILE"
}
trap cleanup_test_containers EXIT

# ─── Source test modules ─────────────────────────────────────────────

# Each module prints its own section header and runs assertions.
# They all share the helpers above (PASS/FAIL/TOTAL are global).

# Source test modules (not bash) so they share the same shell context
# (helpers, PASS/FAIL/TOTAL counters, SCRIPT_DIR, AGENTS)
source "$SCRIPT_DIR/tests/test-commands.sh"
source "$SCRIPT_DIR/tests/test-functions.sh"
source "$SCRIPT_DIR/tests/test-debug-flag.sh"

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════"
echo -e "  Test Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    echo -e "\n${RED}Some tests FAILED.${NC}"
    exit 1
else
    echo -e "\n${GREEN}All tests PASSED!${NC}"
    exit 0
fi
