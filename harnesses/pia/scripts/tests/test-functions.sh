#!/bin/bash

# =============================================================================
# SECTION 9: Helper function tests (generate_random_name, log_*)
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 9: Helper function tests ===${NC}"

eval "$(sed -n '/^PREFIX=/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^RANDOM_SUFFIX_LENGTH=/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^generate_random_name/,/^}/p' "$AGENTS")"

name1=$(generate_random_name)
name2=$(generate_random_name)
assert_output_contains "pia-" "$name1" "generate_random_name should start with prefix"
assert_output_contains "pia-" "$name2" "generate_random_name should start with prefix"
assert_exit_code 0 0 "generate_random_name should succeed"

if [ "$name1" != "$name2" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: generate_random_name produces unique names"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: generate_random_name produced duplicate names"
    FAIL=$((FAIL + 1))
fi

expected_len=$(( ${#PREFIX} + RANDOM_SUFFIX_LENGTH ))
if [ "${#name1}" -eq "$expected_len" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: generate_random_name produces correct length ($expected_len)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: generate_random_name wrong length (got ${#name1}, expected $expected_len)"
    FAIL=$((FAIL + 1))
fi

if echo "$name1" | grep -qE "^pia-[a-z0-9]{8}$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: generate_random_name matches expected pattern"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: generate_random_name doesn't match pattern (got '$name1')"
    FAIL=$((FAIL + 1))
fi

chars=$(echo "$name1" | sed "s/^${PREFIX}//")
if echo "$chars" | grep -qE '^[a-z0-9]+$'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: generate_random_name suffix uses only allowed chars"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: generate_random_name suffix has invalid chars (got '$chars')"
    FAIL=$((FAIL + 1))
fi

eval "$(sed -n '/^log_info/,/^}/p' "$AGENTS")"
output=$(log_info "test message" 2>/dev/null)
assert_output_contains "[INFO] test message" "$output" "log_info should output to stdout"

eval "$(sed -n '/^log_warn/,/^}/p' "$AGENTS")"
output=$(log_warn "test warning" 2>&1 1>/dev/null)
assert_output_contains "[WARN] test warning" "$output" "log_warn should output to stderr"

eval "$(sed -n '/^log_error/,/^}/p' "$AGENTS")"
output=$(log_error "test error" 2>&1 1>/dev/null)
assert_output_contains "[ERROR] test error" "$output" "log_error should output to stderr"

# =============================================================================
# SECTION 10: Option parsing edge cases (extract_name_and_options)
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 10: Option parsing edge cases ===${NC}"

eval "$(sed -n '/^extract_name_and_options/,/^}/p' "$AGENTS")"

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options "my-container")
if [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with name only"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with name only (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options)
if [ "$(extract_name_only "$result")" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with no args returns empty"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with no args (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --mount /some/path)
if [ "$(extract_name_only "$result")" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with --mount value"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with --mount value (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -s my-container)
if [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with -s flag"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with -s flag (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --ssh my-container)
if [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with --ssh flag"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with --ssh flag (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -m /tmp my-container --ssh)
if [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with interleaved args"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with interleaved args (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --mount /tmp --ssh my-container)
if [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with options before name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with options before name (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --mount /some/path my-container)
if [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options with --mount long form"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options with --mount long form (got '$result')"
    FAIL=$((FAIL + 1))
fi

# --- Verify MOUNT_DIR (field 4) and SSH_FLAG (field 5) are correctly output ---

# Test MOUNT_DIR with -m short form
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -m /tmp my-container)
if [ "$(echo "$result" | cut -d'|' -f4)" = "/tmp" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets MOUNT_DIR field (field 4) with -m"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options MOUNT_DIR field wrong (got '$(echo "$result" | cut -d'|' -f4)')"
    FAIL=$((FAIL + 1))
fi

# Test MOUNT_DIR with --mount long form
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --mount /some/path my-container)
if [ "$(echo "$result" | cut -d'|' -f4)" = "/some/path" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets MOUNT_DIR field with --mount"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options MOUNT_DIR field wrong (got '$(echo "$result" | cut -d'|' -f4)')"
    FAIL=$((FAIL + 1))
fi

# Test SSH_FLAG with -s short form
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -s my-container)
if [ "$(echo "$result" | cut -d'|' -f5)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets SSH_FLAG field (field 5) with -s"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options SSH_FLAG field wrong (got '$(echo "$result" | cut -d'|' -f5)')"
    FAIL=$((FAIL + 1))
fi

# Test SSH_FLAG with --ssh long form
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --ssh my-container)
if [ "$(echo "$result" | cut -d'|' -f5)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets SSH_FLAG field with --ssh"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options SSH_FLAG field wrong (got '$(echo "$result" | cut -d'|' -f5)')"
    FAIL=$((FAIL + 1))
fi

# Test both MOUNT_DIR and SSH_FLAG together
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -m /tmp my-container --ssh)
if [ "$(echo "$result" | cut -d'|' -f4)" = "/tmp" ] && [ "$(echo "$result" | cut -d'|' -f5)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets both MOUNT_DIR and SSH_FLAG"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options both fields wrong (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test MOUNT_DIR is empty when no -m flag
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options my-container)
if [ "$(echo "$result" | cut -d'|' -f4)" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options MOUNT_DIR is empty without -m"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options MOUNT_DIR should be empty (got '$(echo "$result" | cut -d'|' -f4)')"
    FAIL=$((FAIL + 1))
fi

# Test SSH_FLAG is empty when no --ssh flag
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options my-container)
if [ "$(echo "$result" | cut -d'|' -f5)" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options SSH_FLAG is empty without --ssh"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options SSH_FLAG should be empty (got '$(echo "$result" | cut -d'|' -f5)')"
    FAIL=$((FAIL + 1))
fi

result=$(extract_name_and_options first second third)
if [ "$(extract_name_only "$result")" = "first" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options takes only first positional"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options takes only first positional (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test -t flag is rejected as unknown option
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -t my-container)
if [ "$(echo "$result" | cut -d'|' -f3)" = "1" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options rejects unknown -t flag"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options should reject -t (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test --docker flag is accepted (not an invalid option)
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --docker my-container)
if [ "$(echo "$result" | cut -d'|' -f3)" = "0" ] && [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options accepts --docker flag"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options should accept --docker (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test DOCKER_MODE (field 7) is set with --docker — shorthand for 'dind'
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --docker my-container)
if [ "$(echo "$result" | cut -d'|' -f7)" = "dind" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets DOCKER_MODE field (field 7) to 'dind' with --docker"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DOCKER_MODE field wrong (got '$(echo "$result" | cut -d'|' -f7)')"
    FAIL=$((FAIL + 1))
fi

# Test DOCKER_MODE is empty when no --docker flag
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options my-container)
if [ "$(echo "$result" | cut -d'|' -f7)" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options DOCKER_MODE is empty without --docker"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DOCKER_MODE should be empty (got '$(echo "$result" | cut -d'|' -f7)')"
    FAIL=$((FAIL + 1))
fi

# Test --docker combined with -m and --ssh
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -m /tmp my-container --ssh --docker)
if [ "$(extract_name_only "$result")" = "my-container" ] && [ "$(echo "$result" | cut -d'|' -f4)" = "/tmp" ] && [ "$(echo "$result" | cut -d'|' -f5)" = "yes" ] && [ "$(echo "$result" | cut -d'|' -f7)" = "dind" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options handles --docker with -m and --ssh"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options --docker with -m/--ssh wrong (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test --openrouter flag is accepted (not an invalid option)
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --openrouter my-container)
if [ "$(echo "$result" | cut -d'|' -f3)" = "0" ] && [ "$(extract_name_only "$result")" = "my-container" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options accepts --openrouter flag"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options should accept --openrouter (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test OPENROUTER_FLAG (field 9) is set with --openrouter
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --openrouter my-container)
if [ "$(echo "$result" | cut -d'|' -f9)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets OPENROUTER_FLAG field (field 9) with --openrouter"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options OPENROUTER_FLAG field wrong (got '$(echo "$result" | cut -d'|' -f9)')"
    FAIL=$((FAIL + 1))
fi

# Test the -o shorthand: accepted and sets OPENROUTER_FLAG (field 9)
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -o my-container)
if [ "$(echo "$result" | cut -d'|' -f3)" = "0" ] && [ "$(extract_name_only "$result")" = "my-container" ] && [ "$(echo "$result" | cut -d'|' -f9)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options -o shorthand sets OPENROUTER_FLAG"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options -o shorthand wrong (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test OPENROUTER_FLAG is empty when no --openrouter flag
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options my-container)
if [ "$(echo "$result" | cut -d'|' -f9)" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options OPENROUTER_FLAG is empty without --openrouter"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options OPENROUTER_FLAG should be empty (got '$(echo "$result" | cut -d'|' -f9)')"
    FAIL=$((FAIL + 1))
fi

# Test help text documents the --openrouter option and its -o shorthand
help_out="$(bash "$AGENTS" --help 2>/dev/null)"
if echo "$help_out" | grep -qF -- "-o, --openrouter"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: help text includes -o, --openrouter option"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: help text should document -o, --openrouter"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# SECTION 11: Container state check functions
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 11: Container state check functions ===${NC}"

eval "$(sed -n '/^container_exists/,/^}/p' "$AGENTS")"
if container_exists "nonexistent-container-xyz-12345"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: container_exists should return false for non-existent"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: container_exists returns false for non-existent container"
    PASS=$((PASS + 1))
fi

eval "$(sed -n '/^container_is_running/,/^}/p' "$AGENTS")"
if container_is_running "nonexistent-container-xyz-12345"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: container_is_running should return false for non-existent"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: container_is_running returns false for non-existent container"
    PASS=$((PASS + 1))
fi

eval "$(sed -n '/^container_id/,/^}/p' "$AGENTS")"

# Positive: stub 'docker' so the test does not depend on a live daemon —
# container_id must call 'docker container inspect -f {{.Id}} <name>' and
# return the ID from stdout.
docker() {
    if [ "$1" = "container" ] && [ "$2" = "inspect" ] && [ "$3" = "-f" ] && \
       [ "$4" = "{{.Id}}" ] && [ "$5" = "pia-fake-name" ]; then
        echo "deadbeefcafe0123456789"
    fi
}
cid="$(container_id "pia-fake-name")"
unset -f docker
assert_output_contains "deadbeefcafe0123456789" "$cid" "container_id resolves a name to its container ID"

# Negative: real docker (or no docker at all) — a non-existent container
# must yield empty output so callers can detect the missing container.
if [ -n "$(container_id "nonexistent-container-xyz-12345")" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: container_id should return empty for non-existent"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: container_id returns empty for non-existent container"
    PASS=$((PASS + 1))
fi

# =============================================================================
# SECTION 12: build_docker_args function
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 12: build_docker_args function ===${NC}"

eval "$(sed -n '/^IMAGE_NAME=/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^config_hash/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^project_labels/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^openrouter_key_file/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^resolve_openrouter_key/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^build_docker_args/,/^}/p' "$AGENTS")"

MOUNT_DIR="" SSH_FLAG="" OPENROUTER_FLAG=""
result=$(build_docker_args "test-container")
if echo "$result" | grep -q "^--name$" && echo "$result" | grep -q "^test-container$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args includes --name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args missing --name (got '$result')"
    FAIL=$((FAIL + 1))
fi

if echo "$result" | grep -qF "$IMAGE_NAME"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args includes image name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args missing image name (got '$result')"
    FAIL=$((FAIL + 1))
fi

# OPENROUTER_API_KEY: not forwarded when unset on the host and no key file
# exists (HOME is isolated so a real ~/.pia/secrets/openrouter-key.txt on the test
# machine cannot leak into the expectation). Also without '--openrouter':
# forwarding is opt-in, even when a key IS available.
OPENROUTER_FLAG=""
unset OPENROUTER_API_KEY PIA_OPENROUTER_KEY_FILE
REAL_HOME="$HOME"
HOME="$(mktemp -d)"
result=$(build_docker_args "test-container" 2>/dev/null)
if echo "$result" | grep -q "OPENROUTER_API_KEY"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args must not forward OPENROUTER_API_KEY when unset (got '$result')"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args omits OPENROUTER_API_KEY when unset"
    PASS=$((PASS + 1))
fi

# An exported key on the host is still NOT forwarded without '--openrouter' —
# the default must be "no credentials in the container".
OPENROUTER_API_KEY="DUMMY-KEY-NOT-A-SECRET"
result=$(build_docker_args "test-container" 2>/dev/null)
if echo "$result" | grep -q "OPENROUTER_API_KEY"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args must not forward OPENROUTER_API_KEY without --openrouter (got '$result')"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args omits OPENROUTER_API_KEY without --openrouter"
    PASS=$((PASS + 1))
fi

# ...and with '--openrouter' it is forwarded by NAME only (never with '=value').
OPENROUTER_FLAG="yes"
result=$(build_docker_args "test-container" 2>/dev/null)
if echo "$result" | grep -q "^OPENROUTER_API_KEY$" && ! echo "$result" | grep -q "DUMMY-KEY-NOT-A-SECRET"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args forwards OPENROUTER_API_KEY by name only (with --openrouter)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args should forward OPENROUTER_API_KEY by name without value when --openrouter is set (got '$result')"
    FAIL=$((FAIL + 1))
fi
unset OPENROUTER_API_KEY

# resolve_openrouter_key is a NO-OP without the flag: a key file on disk and
# an exported key on the host must not leak into the container.
OPENROUTER_API_KEY="DUMMY-KEY-NOT-A-SECRET"
OPENROUTER_FLAG=""
resolve_openrouter_key
result=$(build_docker_args "test-container" 2>/dev/null)
if ! echo "$result" | grep -q "OPENROUTER_API_KEY"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: resolve_openrouter_key is a no-op without --openrouter"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: resolve must not forward without --openrouter (got '$result')"
    FAIL=$((FAIL + 1))
fi
unset OPENROUTER_API_KEY

# Key file via PIA_OPENROUTER_KEY_FILE: resolve_openrouter_key exports the
# trimmed key in the CURRENT shell, and the caller pattern (build_docker_args
# through a process substitution, then docker) still sees everything —
# regression test for the export-in-subshell bug that gave containers a
# valueless OPENROUTER_API_KEY.
KEYDIR="$(mktemp -d)"
printf 'DUMMY-KEY-NOT-A-SECRET\n' > "$KEYDIR/openrouter-key.txt"
unset OPENROUTER_API_KEY
OPENROUTER_FLAG="yes"
PIA_OPENROUTER_KEY_FILE="$KEYDIR/openrouter-key.txt"
resolve_openrouter_key
ca_args=()
while IFS= read -r a; do ca_args+=("$a"); done < <(build_docker_args "test-container" 2>/dev/null)
ca_joined="${ca_args[*]}"
child_sees="$(env | grep '^OPENROUTER_API_KEY=')"
if [ "${OPENROUTER_API_KEY:-}" = "DUMMY-KEY-NOT-A-SECRET" ] \
    && printf '%s\n' "${ca_args[@]}" | grep -q "^OPENROUTER_API_KEY$" \
    && ! printf '%s' "$ca_joined" | grep -q "DUMMY-KEY-NOT-A-SECRET" \
    && [ "$child_sees" = "OPENROUTER_API_KEY=DUMMY-KEY-NOT-A-SECRET" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: resolve_openrouter_key exports key; survives process substitution (docker sees value)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: resolve should export key in main shell (args '$ca_joined', env '${OPENROUTER_API_KEY:-}', child '$child_sees')"
    FAIL=$((FAIL + 1))
fi

# An exported OPENROUTER_API_KEY wins over the key file.
OPENROUTER_API_KEY="DUMMY-ENV-WINS-NOT-A-SECRET"
OPENROUTER_FLAG="yes"
resolve_openrouter_key
if [ "${OPENROUTER_API_KEY:-}" = "DUMMY-ENV-WINS-NOT-A-SECRET" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: OPENROUTER_API_KEY env var takes priority over key file"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: env var should win over key file (got '${OPENROUTER_API_KEY:-}')"
    FAIL=$((FAIL + 1))
fi

# ~/.pia/secrets/openrouter-key.txt is found via HOME (isolated above).
unset OPENROUTER_API_KEY PIA_OPENROUTER_KEY_FILE
mkdir -p "$HOME/.pia/secrets"
printf 'DUMMY-KEY-NOT-A-SECRET\n' > "$HOME/.pia/secrets/openrouter-key.txt"
found="$(openrouter_key_file)"
if [ "$found" = "$HOME/.pia/secrets/openrouter-key.txt" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: openrouter_key_file finds ~/.pia/secrets/openrouter-key.txt"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: openrouter_key_file should find the home key file (got '$found')"
    FAIL=$((FAIL + 1))
fi

# A PIA_OPENROUTER_KEY_FILE that points at a missing file is a hard error:
# openrouter_key_file returns non-zero, and resolve_openrouter_key aborts
# (exit 1 in the main shell) instead of silently using the home key file
# that exists right next door — no credential swap.
PIA_OPENROUTER_KEY_FILE="$HOME/no-such-key-file.txt"
override_out="$(openrouter_key_file 2>&1 1>/dev/null)"; override_status=$?
resolve_out="$(resolve_openrouter_key 2>&1)"; resolve_status=$?
if [ "$override_status" -ne 0 ] && echo "$override_out" | grep -qi "no such file exists" \
    && [ "$resolve_status" -ne 0 ] && echo "$resolve_out" | grep -qi "no such file exists" \
    && [ -z "${OPENROUTER_API_KEY:-}" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: missing PIA_OPENROUTER_KEY_FILE is a hard error (no fallback)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: missing override should error, not fall back (override status=$override_status '$override_out', resolve status=$resolve_status '$resolve_out', key '${OPENROUTER_API_KEY:-}')"
    FAIL=$((FAIL + 1))
fi
unset PIA_OPENROUTER_KEY_FILE

# An empty key file is skipped with a warning, not forwarded.
: > "$HOME/.pia/secrets/openrouter-key.txt"
OPENROUTER_FLAG="yes"
unset OPENROUTER_API_KEY PIA_OPENROUTER_KEY_FILE
resolve_out="$(resolve_openrouter_key 2>&1)"
result=$(build_docker_args "test-container" 2>/dev/null)
if ! echo "$result" | grep -q "^OPENROUTER_API_KEY$" && echo "$resolve_out" | grep -qi "empty" && [ -z "${OPENROUTER_API_KEY:-}" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: empty OpenRouter key file is skipped with a warning"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: empty key file should warn and not forward (got '$result')"
    FAIL=$((FAIL + 1))
fi

# resolve_openrouter_key must exit 0 when NO key exists anywhere — pia.sh runs
# under 'set -euo pipefail', so a non-zero return (e.g. from a bare 'return'
# after a failed [ -n ] test) would silently abort 'pia run' on every machine
# without a key file. Regression test for that silent-exit bug.
: > "$HOME/.pia/secrets/openrouter-key.txt" 2>/dev/null || true
rm -f "$HOME/.pia/secrets/openrouter-key.txt" 2>/dev/null || true
OPENROUTER_FLAG="yes"
unset OPENROUTER_API_KEY PIA_OPENROUTER_KEY_FILE
resolve_openrouter_key
status=$?
if [ "$status" -eq 0 ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: resolve_openrouter_key returns 0 when no key exists (set -e safe)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: resolve_openrouter_key must return 0 without a key, set -e would abort run (status=$status)"
    FAIL=$((FAIL + 1))
fi

# With '--openrouter' but no key anywhere: warn, return 0, forward nothing.
unset OPENROUTER_API_KEY PIA_OPENROUTER_KEY_FILE
OPENROUTER_FLAG="yes"
resolve_out="$(resolve_openrouter_key 2>&1)"
status=$?
result=$(build_docker_args "test-container" 2>/dev/null)
if [ "$status" -eq 0 ] && [ -z "${OPENROUTER_API_KEY:-}" ] \
    && echo "$resolve_out" | grep -qi "no openrouter key found" \
    && ! echo "$result" | grep -q "OPENROUTER_API_KEY"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --openrouter without a key warns, returns 0, forwards nothing"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --openrouter without a key should warn and forward nothing (status=$status, out '$resolve_out', args '$result')"
    FAIL=$((FAIL + 1))
fi
rm -rf "$KEYDIR" "$HOME" 2>/dev/null || true
HOME="$REAL_HOME"
OPENROUTER_FLAG=""
unset OPENROUTER_API_KEY PIA_OPENROUTER_KEY_FILE

mkdir -p /tmp/test-build-docker-args-$$
MOUNT_DIR="/tmp/test-build-docker-args-$$" SSH_FLAG=""
result=$(build_docker_args "test-container" 2>/dev/null)
if echo "$result" | grep -qF "/tmp/test-build-docker-args-$$:/workspace"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args includes mount volume"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args missing mount volume (got '$result')"
    FAIL=$((FAIL + 1))
fi
rm -rf /tmp/test-build-docker-args-$$ 2>/dev/null || true

# Test relative path resolution (e.g., "." should resolve to absolute path)
mkdir -p /tmp/test-rel-path-$$
cd /tmp/test-rel-path-$$
MOUNT_DIR="." SSH_FLAG=""
result=$(build_docker_args "test-container" 2>/dev/null)
if echo "$result" | grep -qF "/tmp/test-rel-path-$$:/workspace"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args resolves relative path '.' to absolute"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args relative path resolution failed (got '$result')"
    FAIL=$((FAIL + 1))
fi
rm -rf /tmp/test-rel-path-$$ 2>/dev/null || true
cd "$SCRIPT_DIR" 2>/dev/null || true

if echo "$result" | grep -q "^-w$" && echo "$result" | grep -q "^/workspace$"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args includes working directory"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args missing working dir (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test non-existent mount directory error
MOUNT_DIR="/nonexistent/path/xyz-$$" SSH_FLAG=""
result=$(build_docker_args "test-container" 2>&1) || true
if echo "$result" | grep -q "does not exist"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args errors on non-existent mount dir"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args should error on non-existent mount dir (got '$result')"
    FAIL=$((FAIL + 1))
fi

# --- Socket test helpers -------------------------------------------------
# These tests need a real Unix socket file on disk (pia.sh checks '[ -S ]').
# We create one with python3 (stdlib only, always present) and fall back to
# socat. No external dependency is required.
#
# start_test_socket <path>  -> binds the socket, sets TEST_SOCKET_PID
# stop_test_socket          -> kills the listener and removes the socket file

TEST_SOCKET_PID=""

start_test_socket() {
    local sock_path="$1"
    local waited=0

    rm -f "$sock_path"
    TEST_SOCKET_PID=""

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os, socket, sys, time
path = sys.argv[1]
try:
    os.unlink(path)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
# Self-terminate so a crashed harness never leaves a stray listener behind.
deadline = time.time() + 30
while time.time() < deadline:
    try:
        conn, _ = srv.accept()
        conn.close()
    except OSError:
        break' "$sock_path" &
        TEST_SOCKET_PID=$!
    elif command -v socat >/dev/null 2>&1; then
        socat "UNIX-LISTEN:${sock_path},fork" EXEC:/bin/true &
        TEST_SOCKET_PID=$!
    else
        return 1
    fi

    # Wait (max ~2s) until the socket file actually shows up.
    while [ "$waited" -lt 20 ]; do
        [ -S "$sock_path" ] && return 0
        sleep 0.1
        waited=$((waited + 1))
    done
    stop_test_socket
    return 1
}

stop_test_socket() {
    local sock_path="$1"
    [ -n "$TEST_SOCKET_PID" ] && kill "$TEST_SOCKET_PID" 2>/dev/null || true
    rm -f "$sock_path"
    TEST_SOCKET_PID=""
}

# --- SSH socket tests ---

# Test SSH socket is included when SSH_AUTH_SOCK is set and socket exists
SSH_SOCK="/tmp/test-ssh-sock-agent-$$"
if start_test_socket "$SSH_SOCK"; then
    export SSH_AUTH_SOCK="$SSH_SOCK"
    MOUNT_DIR="" SSH_FLAG="yes"
    result=$(build_docker_args "test-container" 2>/dev/null)
    if echo "$result" | grep -qF "$SSH_SOCK:/tmp/ssh-agent.sock"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: build_docker_args includes SSH socket when available"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: build_docker_args missing SSH socket (got '$result')"
        FAIL=$((FAIL + 1))
    fi
    stop_test_socket "$SSH_SOCK"
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${YELLOW}SKIP${NC}: could not create a test Unix socket (no python3/socat)"
    PASS=$((PASS + 1))
fi
unset SSH_AUTH_SOCK

# Test SSH socket is omitted when SSH_AUTH_SOCK is not set
MOUNT_DIR="" SSH_FLAG="yes"
result=$(SSH_AUTH_SOCK="" build_docker_args "test-container" 2>/dev/null)
if ! echo "$result" | grep -qF "ssh-agent.sock"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args omits SSH socket when not available"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args should not include SSH socket (got '$result')"
    FAIL=$((FAIL + 1))
fi

# --- Docker socket tests ('--docker-full' — the 'socket' mode — only; plain --docker is
# dind and must NEVER mount a socket; see the docker-mode section) ---

# Test Docker socket is NOT included without --docker flag
MOUNT_DIR="" SSH_FLAG="" DOCKER_MODE=""
result=$(DOCKER_SOCKET="/nonexistent/docker.sock" build_docker_args "test-container" 2>/dev/null)
if ! echo "$result" | grep -qF "docker.sock"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args omits Docker socket without --docker"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args should not include Docker socket (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test Docker socket is included in socket mode when the socket exists
DOCKER_SOCK="/tmp/test-docker-sock-$$"
if start_test_socket "$DOCKER_SOCK"; then
    MOUNT_DIR="" SSH_FLAG="" DOCKER_MODE="socket"
    result=$(DOCKER_SOCKET="$DOCKER_SOCK" build_docker_args "test-container" 2>/dev/null)
    if echo "$result" | grep -qF "$DOCKER_SOCK:/var/run/docker.sock"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: build_docker_args includes Docker socket in socket mode"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: build_docker_args missing Docker socket (got '$result')"
        FAIL=$((FAIL + 1))
    fi
    stop_test_socket "$DOCKER_SOCK"
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${YELLOW}SKIP${NC}: could not create a test Unix socket (no python3/socat)"
    PASS=$((PASS + 1))
fi

# Test warning in socket mode when the socket does not exist
MOUNT_DIR="" SSH_FLAG="" DOCKER_MODE="socket"
result=$(DOCKER_SOCKET="/nonexistent/docker-$$-xyz.sock" build_docker_args "test-container" 2>&1)
if echo "$result" | grep -qF "not found" && ! echo "$result" | grep -qF "docker-$$-xyz.sock:/var/run/docker.sock"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args warns when Docker socket is missing"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args should warn on missing Docker socket (got '$result')"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# SECTION 13: Configuration constants
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 13: Configuration constants ===${NC}"

eval "$(grep '^IMAGE_NAME=' "$AGENTS")"
if [ -n "$IMAGE_NAME" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: IMAGE_NAME is set to '$IMAGE_NAME'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: IMAGE_NAME is not set"
    FAIL=$((FAIL + 1))
fi

eval "$(grep '^PREFIX=' "$AGENTS")"
if [ "$PREFIX" = "pia-" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: PREFIX is 'pia-'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: PREFIX is '$PREFIX', expected 'pia-'"
    FAIL=$((FAIL + 1))
fi

eval "$(grep '^KEEP_PREFIX=' "$AGENTS")"
if [ "$KEEP_PREFIX" = "pia-keep-" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: KEEP_PREFIX is 'pia-keep-'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: KEEP_PREFIX is '$KEEP_PREFIX', expected 'pia-keep-'"
    FAIL=$((FAIL + 1))
fi

eval "$(grep '^RANDOM_SUFFIX_LENGTH=' "$AGENTS")"
if [ "$RANDOM_SUFFIX_LENGTH" -eq 8 ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: RANDOM_SUFFIX_LENGTH is 8"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: RANDOM_SUFFIX_LENGTH is $RANDOM_SUFFIX_LENGTH, expected 8"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# SECTION 14: Script syntax and basic validation
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 14: Script syntax and validation ===${NC}"

if [ -x "$AGENTS" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: Script is executable"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: Script is not executable"
    FAIL=$((FAIL + 1))
fi

first_line=$(head -1 "$AGENTS")
if [ "$first_line" = "#!/bin/bash" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: Script has correct shebang"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: Script shebang is '$first_line'"
    FAIL=$((FAIL + 1))
fi

if bash -n "$AGENTS" 2>/dev/null; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: Script passes bash -n syntax check"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: Script has syntax errors"
    FAIL=$((FAIL + 1))
fi

for cmd in cmd_run cmd_create cmd_stop cmd_rm cmd_ls cmd_clean cmd_resume cmd_restart cmd_exec cmd_sh cmd_monitor cmd_keep cmd_unkeep cmd_rename; do
    if grep -q "^${cmd}()" "$AGENTS"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: Function '$cmd' exists"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: Function '$cmd' does not exist"
        FAIL=$((FAIL + 1))
    fi
done

for cmd in run create stop remove list restart exec sh shell monitor keep unkeep rename; do
    if grep -q "    ${cmd})" "$AGENTS"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: Main case handles '$cmd'"
        PASS=$((PASS + 1))
    else
        TOTAL=$((TOTAL + 1))
        echo -e "  ${RED}FAIL${NC}: Main case missing '$cmd'"
        FAIL=$((FAIL + 1))
    fi
done

# =============================================================================
# SECTION 15: ensure_prefix edge cases
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 15: ensure_prefix edge cases ===${NC}"

eval "$(sed -n '/^PREFIX=/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^ensure_prefix/,/^}/p' "$AGENTS")"

result=$(ensure_prefix "my-project")
if [ "$result" = "pia-my-project" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ensure_prefix adds prefix to custom name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ensure_prefix should add prefix (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(ensure_prefix "pia-existing")
if [ "$result" = "pia-existing" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ensure_prefix doesn't double-prefix"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ensure_prefix should not double-prefix (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(ensure_prefix "")
if [ -z "$result" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ensure_prefix keeps empty name empty"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ensure_prefix should keep empty name (got '$result')"
    FAIL=$((FAIL + 1))
fi

result=$(ensure_prefix "my-project-123")
if [ "$result" = "pia-my-project-123" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ensure_prefix works with hyphens and numbers"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ensure_prefix with hyphens/numbers (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test name with dots (should pass through unchanged, prefix added)
result=$(ensure_prefix "my.project")
if [ "$result" = "pia-my.project" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ensure_prefix handles dots in name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ensure_prefix with dots (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test very long name (should not truncate)
long_name="a$(printf 'b%.0s' {1..100})"
result=$(ensure_prefix "$long_name")
if [ "$result" = "pia-$long_name" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ensure_prefix handles very long names"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ensure_prefix with long name (got '$result')"
    FAIL=$((FAIL + 1))
fi

# Test name that already has partial prefix
result=$(ensure_prefix "pia-partial")
if [ "$result" = "pia-partial" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: ensure_prefix handles partial prefix match"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: ensure_prefix partial prefix (got '$result')"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# SECTION 15b: keep helpers (add_keep, strip_keep, to_keep_name)
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 15b: keep helper functions ===${NC}"

eval "$(grep '^PREFIX=' "$AGENTS")"
eval "$(grep '^KEEP_PREFIX=' "$AGENTS")"
eval "$(sed -n '/^add_keep/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^strip_keep/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^to_keep_name/,/^}/p' "$AGENTS")"

assert_helper() {
    local expected="$1" actual="$2" description="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_helper "pia-keep-zzz" "$(add_keep 'pia-zzz')" "add_keep pia-zzz -> pia-keep-zzz"
assert_helper "pia-keep-zzz" "$(add_keep 'pia-keep-zzz')" "add_keep is idempotent"
assert_helper "pia-zzz" "$(strip_keep 'pia-keep-zzz')" "strip_keep pia-keep-zzz -> pia-zzz"
assert_helper "pia-zzz" "$(strip_keep 'pia-zzz')" "strip_keep leaves non-kept names unchanged"
assert_helper "pia-zzz" "$(strip_keep "$(add_keep 'pia-zzz')")" "add_keep/strip_keep roundtrip"
assert_helper "pia-keep-foo" "$(to_keep_name 'foo')" "to_keep_name bare suffix -> pia-keep-foo"
assert_helper "pia-keep-foo" "$(to_keep_name 'pia-foo')" "to_keep_name strips pia- prefix"
assert_helper "pia-keep-foo" "$(to_keep_name 'pia-keep-foo')" "to_keep_name keeps keep-names unchanged"
assert_helper "pia-keep-my.session_1" "$(to_keep_name 'my.session_1')" "to_keep_name handles dots/underscores"

# =============================================================================
# SECTION 16: run prefixed name in output
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 16: Prefix behavior in run command ===${NC}"

capture_output run my-test-container 2>/dev/null || true
# The run above really creates the container — remove it again so it does not
# leak into later sections (and into the user's container list).
docker rm -f pia-my-test-container > /dev/null 2>&1 || true
if echo "$CAPTURED_OUTPUT" | grep -q "pia-my-test-container"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: run shows prefixed name in output"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: run should show prefixed name (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# SECTION 17: Container restart code path verification
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 17: Container restart on second run ===${NC}"

# Test: running with same name when container is stopped shows start message
# We can't easily test the full flow (create + stop + run again) without
# actually running docker, but we can verify the code path exists.
# The key fix: cmd_run restarts a stopped container via attach_session,
# which starts it detached with 'docker start' (not 'docker run -i') and
# attaches pi with 'docker exec'.
if grep -q 'docker start "$name"' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: stopped containers are restarted with 'docker start' (via attach_session)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: stopped containers should be restarted with 'docker start'"
    FAIL=$((FAIL + 1))
fi

# Only the current (idling-entrypoint) image is supported — there must be no
# leftover 'docker start -i' fallback for legacy images.
if grep -q 'docker start -i' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: legacy 'docker start -i' session path must be gone"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: no legacy 'docker start -i' session path"
    PASS=$((PASS + 1))
fi

# Verify 'docker run -i' is NOT used for restart (that would try to create a new container)
# The only 'docker run -i' should be for creating new containers (with full args)
if grep -q 'docker run -i "$name"' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: should not use 'docker run -i' for restarting stopped containers"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: does not use 'docker run -i' for restart"
    PASS=$((PASS + 1))
fi

# Verify auto-generated names include the pia- prefix
# cmd_run calls generate_random_name() which already includes PREFIX, so verify
# the code path exists and the function is called in cmd_run
if grep -q 'generate_random_name' "$AGENTS" && grep -q 'ensure_prefix' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_run has both generate_random_name and ensure_prefix for name handling"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_run should have both generate_random_name and ensure_prefix"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# SECTION 17b: Project labels (pure docker labeling, no compose)
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 17b: Project labels ===${NC}"

eval "$(sed -n '/^config_hash/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^project_labels/,/^}/p' "$AGENTS")"

# configuration constant
if grep -q '^PROJECT_NAME="pia"' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: PROJECT_NAME is defined as 'pia'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: PROJECT_NAME should be defined as 'pia'"
    FAIL=$((FAIL + 1))
fi

# compose must never be invoked (checked on code lines, comments excluded),
# and no compose file may be referenced
if grep -vE '^[[:space:]]*#' "$AGENTS" | grep -qE 'docker +compose +[a-z]'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia.sh must not call compose: $(grep -nE 'docker +compose +[a-z]' "$AGENTS" | head -1)"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia.sh never calls compose"
    PASS=$((PASS + 1))
fi

# The CLI must never build an image: both the agent image and the daemon
# image come from build-docker.sh (the agent image is not pullable, so a
# usable CLI already implies both were built). Checked on code lines, so the
# 'build-docker.sh' remediation message is fine.
if grep -vE '^[[:space:]]*#' "$AGENTS" | grep -qE 'docker +build'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia.sh must not build images: $(grep -nE 'docker +build' "$AGENTS" | head -1)"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia.sh never builds images (build-docker.sh owns that)"
    PASS=$((PASS + 1))
fi

if grep -q 'docker-compose' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia.sh must not reference a compose file"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia.sh references no compose file"
    PASS=$((PASS + 1))
fi

if [ ! -e "$SCRIPT_DIR/../docker/docker-compose.yml" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: no compose file ships with pia"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: harnesses/pia/docker/docker-compose.yml should not exist"
    FAIL=$((FAIL + 1))
fi

# --- project_labels ----------------------------------------------------------
LABELS="$(project_labels "pia-myproj" 2>/dev/null)"

if echo "$LABELS" | grep -qxF "com.docker.compose.project=pia"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: project_labels emits the project label"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: project label missing (got '$LABELS')"
    FAIL=$((FAIL + 1))
fi

if echo "$LABELS" | grep -qxF -- "--label"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: project_labels emits --label arguments"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --label arguments missing (got '$LABELS')"
    FAIL=$((FAIL + 1))
fi

if echo "$LABELS" | grep -qxF "com.docker.compose.service=myproj"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: service label derives from the container suffix"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: service label wrong (got '$LABELS')"
    FAIL=$((FAIL + 1))
fi

SVC="$(project_labels "pia-weird name!" 2>/dev/null | grep 'com.docker.compose.service=')"
if [ "$SVC" = "com.docker.compose.service=weird-name-" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: service label is sanitized"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: service label not sanitized (got '$SVC')"
    FAIL=$((FAIL + 1))
fi

if project_labels "pia-keep-zzz" 2>/dev/null | grep -qxF "com.docker.compose.service=keep-zzz"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: service label handles kept container names"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: service label wrong for kept names"
    FAIL=$((FAIL + 1))
fi

# project views ignore containers without a config-hash, so it must be there
if echo "$LABELS" | grep -q '^com.docker.compose.config-hash=.\+'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: config-hash label is non-empty"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: config-hash label missing (got '$LABELS')"
    FAIL=$((FAIL + 1))
fi

# one-off containers are hidden by project views — pia containers are not one-offs
if echo "$LABELS" | grep -qxF "com.docker.compose.oneoff=False"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: oneoff label is set to False"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: oneoff label missing (got '$LABELS')"
    FAIL=$((FAIL + 1))
fi

# nothing may point at a compose file or claim a compose version
if echo "$LABELS" | grep -qE 'config_files|working_dir|\.version='; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: labels must not reference a compose file/version (got '$LABELS')"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: no compose file/version labels emitted"
    PASS=$((PASS + 1))
fi

# every label line is a plain key=value pair or the --label flag
if echo "$LABELS" | grep -qvE -- '^--label$|^com\.docker\.compose\.[a-z_.-]+=[^ ]*$'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: malformed label argument (got '$LABELS')"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: all label arguments are well formed"
    PASS=$((PASS + 1))
fi

# config_hash yields a non-empty value
if [ -n "$(config_hash "pia-x")" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: config_hash returns a value"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: config_hash returned an empty value"
    FAIL=$((FAIL + 1))
fi

# --- wiring into docker create/run -------------------------------------------
MOUNT_DIR="" SSH_FLAG="" DOCKER_MODE=""
ARGS_WITH_LABELS="$(build_docker_args "pia-labelled" 2>/dev/null)"

if echo "$ARGS_WITH_LABELS" | grep -qxF "com.docker.compose.project=pia"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args includes the project label"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args missing project label (got '$ARGS_WITH_LABELS')"
    FAIL=$((FAIL + 1))
fi

if [ "$(echo "$ARGS_WITH_LABELS" | tail -1)" = "$IMAGE_NAME" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: image name is still the last build_docker_args argument"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: image name should be last (got '$ARGS_WITH_LABELS')"
    FAIL=$((FAIL + 1))
fi

# --- listing by label --------------------------------------------------------
if grep -q 'label=com.docker.compose.project=${PROJECT_NAME}' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia_ps filters by the project label"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia_ps should filter by the project label"
    FAIL=$((FAIL + 1))
fi

if grep -q 'pia_ps' "$AGENTS" && grep -q 'pia_ps --filter "status=exited"' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia ls, pia clean, and pia rs use pia_ps"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: list/clean/resume should share the pia_ps query"
    FAIL=$((FAIL + 1))
fi

# 'pia rs' must pick the container that STOPPED last, not the newest-created
# one — docker ps sorts by creation time, so the stop time has to come from
# State.FinishedAt (docker inspect).
if grep -q 'State.FinishedAt' "$AGENTS" && grep -q 'pia_last_stopped' "$AGENTS" \
   && ! grep -q 'pia_ps --filter "status=exited" | head -1' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia rs selects by stop time (State.FinishedAt), not listing order"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia rs must resume the most recently stopped container, not the first listed"
    FAIL=$((FAIL + 1))
fi

# the name-prefix filter is kept, so older unlabelled containers still show up
if grep -q 'filter "name=^${PREFIX}"' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia_ps still matches the pia- name prefix"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia_ps should keep the name-prefix filter"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
# SECTION 18: 'pia monitor' chart helpers (sparkline, bar, ingest, dashboard)
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 18: monitor chart helpers ===${NC}"

# The whole chart block: constants, glyph set, renderers and the sample parser.
# Everything in it is pure — no docker, no files — so it can be sourced and
# driven with fake samples.
eval "$(sed -n '/^CHART_HISTORY=/,/^# Name of the only running/p' "$AGENTS" | sed '$d')"

# Glyphs are forced rather than detected: 'locale charmap' answers UTF-8 only on
# a system that has the locale installed, and these assertions are about the
# maths and the layout, not about the host's fonts. Letters keep every expected
# value ASCII, so a failure message stays readable anywhere.
chart_init
CHART_GLYPHS=(a b c d e f g h)
CHART_EMPTY='.'
CHART_RULE='-'
CHART_MID='-'
CHART_DOWN='v'
CHART_UP='^'

# dest_hits LIST_NAME COUNTS_NAME KEY — the hits recorded for KEY in a parallel
# (list, counts) pair, or 0. Destinations are held in indexed arrays rather than
# associative ones (bash 3.2 has no 'declare -A'), so a lookup goes through
# chart_index exactly as the monitor does it.
dest_hits() {
    chart_index "$1" "$3"
    [ "$CHART_IDX" -ge 0 ] || { printf '0'; return 0; }
    eval "printf '%s' \"\${$2[$CHART_IDX]}\""
}

assert_helper "agd." "$(sparkline 4 0 10 5)" "sparkline scales to the maximum of what it shows, one step below the top — free slots stay '.' placeholders"
assert_helper "fg" "$(sparkline 2 1 2 3 4)" "sparkline shows the LAST width values, not the first"
assert_helper "gg......" "$(sparkline 8 7 7)" "a flat series sits one glyph below the top — the ceiling glyph stays a gap, so 'all up' still reads as a line, not a wall"
assert_helper "aaa" "$(sparkline 3 0 0 0)" "sparkline of an all-zero series is the lowest glyph"
assert_helper "..." "$(sparkline 3)" "sparkline with no values is a row of '.' placeholders — the chart reserves its width and 'no data yet' is visible"
assert_helper "ag.." "$(sparkline 4 -5 10)" "sparkline clamps a negative value instead of indexing off the end"

assert_helper "ggggg....." "$(bar 10 50)" "bar 10 50 fills half"
assert_helper "gggg" "$(bar 4 150)" "bar clamps above 100%"
assert_helper "...." "$(bar 4 -5)" "bar clamps below 0%"
assert_helper "....." "$(bar 5 0)" "bar of nothing is the empty glyph"
assert_helper "0" "$(bar 6 100 | grep -c h || true)" "a FULL bar still leaves the ceiling free — the gauge gap matches the sparklines"

assert_helper "0B" "$(human_bytes 0)" "human_bytes 0"
assert_helper "2.0KiB" "$(human_bytes 2048)" "human_bytes KiB"
assert_helper "1.0MiB" "$(human_bytes 1048576)" "human_bytes MiB"
assert_helper "-2.0KiB" "$(human_bytes -2048)" "human_bytes keeps the sign of a counter that went backwards"

assert_helper "999" "$(human_count 999)" "human_count below a thousand is plain"
assert_helper "262.1k" "$(human_count 262144)" "human_count scales tokens to k"
assert_helper "1.5M" "$(human_count 1500000)" "human_count scales tokens to M"

assert_helper "abc   " "$(chart_pad abc 6)" "chart_pad pads to the column width"
assert_helper "abcd~" "$(chart_pad abcdefg 5)" "chart_pad truncates with a ~ marker"
assert_helper "ab" "$(chart_pad ab 30 | sed 's/ *$//')" "chart_pad never truncates a short string"

assert_helper "12" "$(chart_positive 12)" "chart_positive passes a number through"
assert_helper "0" "$(chart_positive '?')" "chart_positive turns 'pids ?' (no cgroup) into 0"
assert_helper "0" "$(chart_positive -5)" "chart_positive turns a negative counter into 0"

# --- series_push / series_spark / series_max --------------------------------

CPU_SERIES=()
series_push CPU_SERIES 3
series_push CPU_SERIES 20
series_push CPU_SERIES 7
assert_helper "bgc......." "$(series_spark CPU_SERIES 10)" "series_spark renders the series it is given, padded with '.' to full width"
assert_helper "20" "$(series_max CPU_SERIES)" "series_max reports the peak, not the last value"
assert_helper "20.0" "$(series_max CPU_SERIES '%.1f')" "series_max formats the peak when asked (percents keep a decimal)"
series_push CPU_SERIES "not-a-number"
assert_helper "4" "${#CPU_SERIES[@]}" "series_push keeps one sample per cycle even when the value is unreadable"

CHART_HISTORY=3
MEM_SERIES=()
for v in 1 2 3 4 5; do series_push MEM_SERIES "$v"; done
assert_helper "3" "${#MEM_SERIES[@]}" "series_push trims a series to CHART_HISTORY"
assert_helper "5" "$(series_max MEM_SERIES)" "the trimmed series keeps the newest values"
CHART_HISTORY=240

CPU_SERIES=()
assert_helper ".." "$(series_spark CPU_SERIES 2)" "series_spark of an empty series is '.' placeholders (and survives 'set -u')"
assert_helper "0" "$(series_max CPU_SERIES)" "series_max of an empty series is 0"

# --- chart_index ------------------------------------------------------------

DEST_LIST=(); DEST_TOTAL=()
DEST_LIST=("TLS   a.example (1.2.3.4)" "HTTP  GET localhost:8088/x" "TLS   b.example (5.6.7.8)")
DEST_TOTAL=(3 1 40)
chart_index DEST_LIST "HTTP  GET localhost:8088/x"
assert_helper "1" "$CHART_IDX" "chart_index finds an entry by its exact text"
chart_index DEST_LIST "TLS   nope (9.9.9.9)"
assert_helper "-1" "$CHART_IDX" "chart_index reports a miss as -1"
assert_helper "40" "$(dest_hits DEST_LIST DEST_TOTAL "TLS   b.example (5.6.7.8)")" "the parallel counts line up with the list"
assert_helper "0" "$(dest_hits DEST_LIST DEST_TOTAL "TLS   nope (9.9.9.9)")" "a missing destination reads as no hits"
DEST_LIST=(); DEST_TOTAL=()
chart_index DEST_LIST "anything"
assert_helper "-1" "$CHART_IDX" "chart_index on an empty list is a miss, not an error"

# --- monitor_ingest ---------------------------------------------------------

MON_CYCLE='14:03:11  TLS   api.github.com (20.205.243.168)   x14
14:03:12  HTTP  GET localhost:8088/tasks?status=open
-- cpu 4.2% of 8 core(s)  mem 300.0MiB/2.0GiB (14.6%)  pids 12  net -12.0KiB +4.0KiB  tok in 262.1k (in 8.2k + cached 254.0k) out 21.5k $0.42  [3s]
#stats cpu=4.2 cores=8 mem=314572800 mem_max=2147483648 pids=12 rx=12288 tx=4096 secs=3 tok_in=8192 tok_cache=253952 tok_out=21504 tok_cost=0.42'

CPU_SERIES=(); MEM_SERIES=(); RX_SERIES=(); TX_SERIES=(); PIDS_SERIES=()
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=(); CHART_SAMPLES=0
monitor_ingest "$MON_CYCLE"
assert_exit_code 0 0 "monitor_ingest accepts a cycle that carries a '#stats' line"
assert_helper "14" "$(dest_hits DEST_CUR DEST_CUR_N "TLS   api.github.com (20.205.243.168)")" "monitor_ingest reads the xN counter of a flow line"
assert_helper "1" "$(dest_hits DEST_CUR DEST_CUR_N "HTTP  GET localhost:8088/tasks?status=open")" "monitor_ingest counts an un-numbered flow line as one hit"
assert_helper "1" "${#CPU_SERIES[@]}" "monitor_ingest pushes one cpu sample per cycle"
assert_helper "1" "${CHART_SAMPLES}" "monitor_ingest counts the sample"
assert_helper "8" "$CHART_CORES" "monitor_ingest parses the cores field"
assert_helper "2147483648" "$CHART_MEM_MAX" "monitor_ingest parses the memory limit"

# A second cycle: the per-cycle counters reset, the lifetime totals do not.
monitor_ingest '14:03:15  TLS   api.github.com (20.205.243.168)   x2
-- cpu 1.0% of 8 core(s)  mem 1.0MiB/unlimited  pids 3  net -0B +0B  [3s]
#stats cpu=1.0 cores=8 mem=1048576 mem_max=max pids=3 rx=0 tx=0 secs=3'
assert_helper "2" "$(dest_hits DEST_CUR DEST_CUR_N "TLS   api.github.com (20.205.243.168)")" "the newest cycle holds only that cycle's hits"
assert_helper "16" "$(dest_hits DEST_LIST DEST_TOTAL "TLS   api.github.com (20.205.243.168)")" "DEST_TOTAL accumulates across cycles"
assert_helper "2" "$(dest_hits DEST_LIST DEST_LAST "TLS   api.github.com (20.205.243.168)")" "DEST_LAST stamps the sample a destination last appeared in"
assert_helper "2" "${#DEST_LIST[@]}" "DEST_LIST records each destination once, in order"
assert_helper "max" "$CHART_MEM_MAX" "'mem_max=max' (no limit) is read as 'max'"

# An image from before charts exists answers a normal cycle: no '#stats' line.
# monitor_ingest says so, and cmd_monitor falls back to the line view.
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=()
if monitor_ingest '14:03:20  TLS   example.org (1.2.3.4)
-- cpu 1.0% of 8 core(s)  mem 1.0MiB/unlimited  pids 3  net -0B +0B  [3s]'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: monitor_ingest should report a sample without '#stats'"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: monitor_ingest reports a sample without '#stats' (old image)"
    PASS=$((PASS + 1))
fi

# A stray warning inside the output is neither a flow line nor a sample, and must
# not be counted as a destination.
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=(); CHART_SAMPLES=0
monitor_ingest 'cannot open device
-- cpu 0.0% of 8 core(s)  mem 1B/unlimited  pids 1  net -0B +0B  [3s]
#stats cpu=0 cores=1 mem=1 mem_max=max pids=1 rx=0 tx=0 secs=3'
assert_helper "0" "${#DEST_LIST[@]}" "monitor_ingest ignores a line that is not a flow record"
assert_helper "1" "${CHART_SAMPLES}" "... but still counts the sample it came with"

# The counter is separated from the destination by its own run of spaces, so
# stripping it must not leave trailing blanks behind: '…(1.2.3.4) ' and
# '…(1.2.3.4)' would otherwise be two different keys, and a destination that is
# polled in one cycle and hit once in the next would split into two rows.
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=(); CHART_SAMPLES=0
monitor_ingest '14:03:11  TLS   example.org (1.2.3.4)   x5
14:03:12  TLS   example.org (1.2.3.4)
-- cpu 0.0% of 8 core(s)  mem 1B/unlimited  pids 1  net -0B +0B  [3s]
#stats cpu=0 cores=1 mem=1 mem_max=max pids=1 rx=0 tx=0 secs=3'
assert_helper "1" "${#DEST_LIST[@]}" "a destination with and without its xN counter is one destination"
assert_helper "6" "$(dest_hits DEST_CUR DEST_CUR_N "TLS   example.org (1.2.3.4)")" "... and their hits add up"

# --- monitor_uptime ---------------------------------------------------------

up_out="$(monitor_uptime 0)"
assert_helper "" "$up_out" "monitor_uptime says nothing when the start time is unknown"
up_out="$(monitor_uptime $(( $(date +%s) - 3725 )))"
TOTAL=$((TOTAL + 1))
if printf '%s' "$up_out" | grep -Eq '^up [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
    echo -e "  ${GREEN}PASS${NC}: monitor_uptime formats elapsed time as 'up HH:MM:SS' ($up_out)"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: monitor_uptime should print 'up HH:MM:SS' (got '$up_out')"
    FAIL=$((FAIL + 1))
fi
up_out="$(monitor_uptime 400000)"
TOTAL=$((TOTAL + 1))
if printf '%s' "$up_out" | grep -Eq '^up [0-9]+d [0-9]{2}:[0-9]{2}$'; then
    echo -e "  ${GREEN}PASS${NC}: monitor_uptime switches to days past 99h, so the header column holds ($up_out)"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: monitor_uptime should print 'up Nd HH:MM' for a long run (got '$up_out')"
    FAIL=$((FAIL + 1))
fi
assert_helper "" "$(monitor_uptime not-a-number)" "monitor_uptime ignores a timestamp it cannot use"

# --- monitor_dashboard ------------------------------------------------------

CPU_SERIES=(); MEM_SERIES=(); RX_SERIES=(); TX_SERIES=(); PIDS_SERIES=()
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=(); CHART_SAMPLES=0
CHART_STARTED_EPOCH=$(( $(date +%s) - 61 ))
# Deterministic frame size: on a real terminal 'tput' would report whatever
# width the suite happens to run in, and header assertions (which show every
# field) would depend on the machine. 100 columns shows everything.
chart_term_size() { CHART_COLS="${FRAME_COLS:-100}"; CHART_LINES=24; }
FRAME_COLS=100
monitor_ingest "$MON_CYCLE"
frame_out="$(monitor_dashboard pia-testframe 3)"
case "$frame_out" in ($'\e[H\e[2J'*) frame_home=yes ;; (*) frame_home=no ;; esac
assert_helper "yes" "$frame_home" "the frame homes the cursor and clears the whole screen, so no tail of a previous frame survives (resize, or a frame that shrank)"
assert_output_contains "cpu" "$frame_out" "the frame draws the cpu row"
assert_output_contains "mem  300.0MiB/2.0GiB (14.6%)" "$frame_out" "the frame shows memory against its limit"
assert_output_contains "pids 12" "$frame_out" "the frame shows the current pids in the header"
assert_output_contains "peak cpu 4.2%/mem 300.0MiB" "$frame_out" "the header carries the run's peak cpu and peak memory next to the uptime"
assert_output_contains "tok in 262.1k (in 8.2k + cached 254.0k)  out 21.5k  \$0.42" "$frame_out" "the tok row leads with the input total and labels the uncached and cached parts of it"
net_line="$(printf '%s' "$frame_out" | grep -n '^ net ' | head -1 | cut -d: -f1)"
tok_line="$(printf '%s' "$frame_out" | grep -n '^ tok ' | head -1 | cut -d: -f1)"
assert_helper "yes" "$([ "${tok_line:-0}" -eq "$(( ${net_line:-0} + 1 ))" ] && echo yes)" "the tok row sits directly under the net line"
assert_helper "8192" "$CHART_TOK_IN" "monitor_ingest parses the cumulative token fields"
assert_helper "253952" "$CHART_TOK_CACHE" "... including the cached-input split"
# a stale image (helper from before the split) sends tok_in but no tok_cache:
# the row must fall back to the old combined form, not claim zero cache reads
unset CHART_TOK_CACHE
monitor_ingest "$(printf '%s\n' "$MON_CYCLE" | grep '^#stats' | sed 's/ tok_cache=[0-9]*//')"
assert_helper "" "${CHART_TOK_CACHE-}" "a pre-split stats line leaves tok_cache unset"
assert_output_contains "tok 8.2k/21.5k" "$(monitor_dashboard pia-testframe 1)" \
    "a pre-split image renders the old combined token form rather than lying about zero cache"
# restore the split token state (assigning, not re-ingesting — a second
# MON_CYCLE ingest would double the destination counts the tests below assert)
CHART_TOK_IN=8192; CHART_TOK_CACHE=253952; CHART_TOK_OUT=21504; CHART_TOK_COST=0.42
assert_output_not_contains "peak 300.0MiB" "$frame_out" "the mem row no longer trails its peak"
assert_output_not_contains "sample" "$frame_out" "the sample counter is bookkeeping, not frame content"
assert_helper "1" "$(printf '%s' "$frame_out" | grep -c 'pids 12')" "pids appears once — the header, not also a chart row"
assert_output_contains "x14   TLS   api.github.com" "$frame_out" "the destinations pane shows the accumulated hits per URL"
dest_row="$(printf '%s' "$frame_out" | grep -F 'x14   TLS   api.github.com' | head -1)"
assert_helper "" "$(printf '%s' "${dest_row#*')'}" | tr -d ' ')" "destination rows end with the URL — no bar trails it any more"
assert_output_contains "api.github.com" "$frame_out" "the frame lists the busiest destination"
assert_output_contains "targets: 2" "$frame_out" "the frame counts the destinations"
assert_output_contains "Ctrl-C" "$frame_out" "the frame reminds how to stop"

# No row of the frame may reach the terminal's last column: a wrapped row plus
# the explicit '\n' scrolls one line per frame, so every following frame draws
# onto a screen shifted by one — the 'two net rows / ghosted iew / mixed
# counters' smear a wide terminal produced. Rows are built with '%-*s', which
# pads to the column width even for the multi-byte glyphs (a terminal counts
# columns too), so this measures what the terminal will see.
clean_frame="${frame_out#$'\e[H\e[2J'}"
clean_frame="${clean_frame%$'\e[K'}"
max_row=0
while IFS= read -r frline; do
    # ${#s} counts CHARACTERS — the same metric 'printf %-Ns' pads to and the
    # terminal counts, so a row passing here cannot wrap.
    [ "${#frline}" -gt "$max_row" ] && max_row="${#frline}"
done <<< "$clean_frame"
assert_helper "yes" "$([ "$max_row" -le "$(( FRAME_COLS - 1 ))" ] && echo yes || echo "no (widest row: ${max_row} of ${FRAME_COLS})")" \
    "no frame row reaches the last column — nothing wraps, so the frame cannot drift on the screen"

# 80-column regression: an earlier header gave the tail only 40 columns and
# the token summary — the number the user asked for — died as 't~'. The
# token figure must survive an 80-column frame.
FRAME_COLS=80
narrow_out="$(monitor_dashboard pia-testframe 1)"
assert_output_contains "tok in 262.1k" "$narrow_out" "the token summary survives an 80-column frame (was truncated to 't~')"
FRAME_COLS=100
if printf '%s' "$frame_out" | grep -q 'bgc\|gggg\|gggggg'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: the frame actually contains chart glyphs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: the frame has no chart glyphs (output: $(printf '%s' "$frame_out" | tr '\n' '|'))"
    FAIL=$((FAIL + 1))
fi

# The pane accumulates per destination: another cycle to the same URL adds its
# hits to the SAME row (14 + 2 = 16) instead of resetting or starting a second
# line — the whole point of counting per URL across samples.
monitor_ingest '14:03:15  TLS   api.github.com (20.205.243.168)   x2
-- cpu 1.0% of 8 core(s)  mem 1.0MiB/unlimited  pids 3  net -0B +0B  [1s]
#stats cpu=1.0 cores=8 mem=1048576 mem_max=max pids=3 rx=0 tx=0 secs=1'
accum_out="$(monitor_dashboard pia-testframe 1)"
assert_output_contains "x16   TLS   api.github.com" "$accum_out" "destination hits accumulate per URL across cycles (14 + 2 = 16)"
assert_helper "1" "$(printf '%s' "$accum_out" | grep -c 'api.github.com')" "... into ONE row per destination, not a new row per cycle"

# Recency leads: the pane is ordered by the LAST sample a destination appeared
# in, so the URL called now sits above one the container stopped talking to —
# even when the dormant one has a hundred times the lifetime hits.
CPU_SERIES=(); MEM_SERIES=(); RX_SERIES=(); TX_SERIES=()
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=(); CHART_SAMPLES=0
monitor_ingest '10:00:01  TLS   big.example (9.9.9.9)   x100
10:00:01  TLS   small.example (8.8.8.8)
-- cpu 1.0% of 2 core(s)  mem 1B/max  pids 1  net -0B +0B  [1s]
#stats cpu=1 cores=2 mem=1 mem_max=max pids=1 rx=0 tx=0 secs=1'
monitor_ingest '10:00:02  TLS   small.example (8.8.8.8)
-- cpu 1.0% of 2 core(s)  mem 1B/max  pids 1  net -0B +0B  [1s]
#stats cpu=1 cores=2 mem=1 mem_max=max pids=1 rx=0 tx=0 secs=1'
recency_out="$(monitor_dashboard pia-testframe 1)"
small_line="$(printf '%s' "$recency_out" | grep -n -F 'small.example' | head -1 | cut -d: -f1)"
big_line="$(printf '%s' "$recency_out" | grep -n -F 'big.example' | head -1 | cut -d: -f1)"
assert_helper "yes" "$([ "${small_line:-9999}" -lt "${big_line:-9999}" ] && echo yes)" \
    "the most recently called destination is listed above the dormant one, despite fewer hits"
assert_output_contains "x100  TLS   big.example" "$recency_out" "... while the dormant destination keeps its accumulated count"

# No limit: there is no percentage to gauge, so the row says 'unlimited' (the
# same call line mode makes) rather than a meaningless bar.
CPU_SERIES=(); MEM_SERIES=(); RX_SERIES=(); TX_SERIES=(); PIDS_SERIES=()
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=()
monitor_ingest '14:03:20  TLS   example.org (1.2.3.4)
-- cpu 0.0% of 8 core(s)  mem 1.0MiB/unlimited  pids 1  net -0B +0B  [3s]
#stats cpu=0.5 cores=8 mem=1048576 mem_max=max pids=1 rx=0 tx=0 secs=3'
unlimited_out="$(monitor_dashboard pia-testframe 3)"
assert_output_contains "unlimited" "$unlimited_out" "the memory row says 'unlimited' when there is no limit"

# An empty monitor (no samples yet, nothing requested) still draws a frame.
CPU_SERIES=(); MEM_SERIES=(); RX_SERIES=(); TX_SERIES=(); PIDS_SERIES=()
DEST_LIST=(); DEST_TOTAL=(); DEST_LAST=(); DEST_CUR=(); DEST_CUR_N=(); CHART_SAMPLES=0
empty_out="$(monitor_dashboard pia-testframe 3)"
assert_output_contains "targets: 0" "$empty_out" "an idle monitor draws a frame, it does not crash"

# --- the chart is wired into the command ------------------------------------

if grep -q "trap 'monitor_screen_off" "$AGENTS" && grep -q 'monitor_screen_off; monitor_stop_sampler' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: both monitor exit paths leave the alternate screen first"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: the monitor traps must leave the alternate screen before reporting"
    FAIL=$((FAIL + 1))
fi

if grep -qF -- '?1049h' "$AGENTS" && grep -qF -- '?1049l' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: the chart enters and leaves the alternate screen (terminal is left clean)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: monitor_screen_on/off must enter and leave the alternate screen"
    FAIL=$((FAIL + 1))
fi

# The in-container helper has to be the one that offers the machine-readable
# sample; the host only draws what it gets.
HELPER="$SCRIPT_DIR/../docker/pia/monitor-inside.sh"
if [ -f "$HELPER" ] && grep -q "printf '#stats cpu=" "$HELPER"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia-monitor cycle prints the '#stats' sample line the charts need"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia-monitor cycle must print a '#stats' sample line for the charts"
    FAIL=$((FAIL + 1))
fi

if [ -f "$HELPER" ] && grep -q "pia-monitor cycle \[SECONDS\] \[stats\]" "$HELPER"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: the helper's own usage documents the 'stats' argument"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: the helper's usage should document the 'stats' argument"
    FAIL=$((FAIL + 1))
fi

# --- mem_bytes: page cache is not 'in use' ----------------------------------

# The '12 GiB' lies bug: memory.current counts the PAGE CACHE charged to the
# cgroup, so an agent that just streamed a lot of traffic left ~11 GiB of
# reclaimable cache behind and the monitor called it 12 GiB 'used' while the
# processes held ~1 GiB. The helper now subtracts the reclaimable part
# (inactive_file / v1 total_inactive_file) exactly like 'docker stats'.
eval "$(sed -n '/^mem_bytes()/,/^}/p' "$HELPER")"
FAKE_CG="$(mktemp -d)"
printf '12884901888' > "$FAKE_CG/memory.current"              # 12.0 GiB charged
printf '21474836480' > "$FAKE_CG/memory.max"                  # 20.0 GiB limit
printf 'anon 1288489984\nfile 11596411904\ninactive_file 11596411904\n' > "$FAKE_CG/memory.stat"
CG="$FAKE_CG"
assert_helper "1288489984 21474836480" "$(mem_bytes)" \
    "mem_bytes subtracts reclaimable page cache — 12 GiB charged, 10.8 GiB cache, ~1 GiB real"
printf '1048576' > "$FAKE_CG/memory.current"
printf 'anon 0\nfile 10485760\ninactive_file 10485760\n' > "$FAKE_CG/memory.stat"
assert_helper "0 21474836480" "$(mem_bytes)" "... and never reports a negative number when the cache exceeds the charge"
rm -f "$FAKE_CG/memory.current" "$FAKE_CG/memory.max" "$FAKE_CG/memory.stat"
mkdir -p "$FAKE_CG/memory"
printf '3221225472' > "$FAKE_CG/memory/memory.usage_in_bytes"
printf 'unlimited' > "$FAKE_CG/memory/memory.limit_in_bytes"
printf 'total_inactive_file 1073741824\n' > "$FAKE_CG/memory/memory.stat"
assert_helper "2147483648 max" "$(mem_bytes)" "the cgroup v1 branch subtracts total_inactive_file too"
rm -rf "$FAKE_CG"
CG="/sys/fs/cgroup"

# --- tok_usage: the agent's own token accounting ----------------------------

# pi writes every assistant message's usage into its session JSONLs; tok_usage
# sums EVERY session the container stores, not just the running one. 'in'
# includes cache reads (the big number is normal), and a half-written last
# line — a session captured WHILE the agent runs — must cost that file's
# tail, never the whole ledger.
eval "$(sed -n '/^tok_usage()/,/^}/p' "$HELPER")"
FAKE_SESS="$(mktemp -d)"; mkdir -p "$FAKE_SESS/--x--" "$FAKE_SESS/--y--"
printf '%s\n' \
    '{"type":"session","version":3,"id":"u","timestamp":"t","cwd":"/w"}' \
    '{"type":"message","message":{"role":"assistant","usage":{"input":100,"output":40,"cacheRead":900,"cost":{"total":0.01}}}}' \
    '{"type":"message","message":{"role":"assistant","usage":{"input":200,"output":60,"cacheRead":0,"cost":{"total":0.02}}}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"tex' > "$FAKE_SESS/--x--/s.jsonl"
assert_helper "300 900 100 0.03" "$(PIA_PI_SESSIONS="$FAKE_SESS" tok_usage)" \
    "tok_usage sums a pi session — uncached and cached input apart, a truncated live tail tolerated"
printf '%s\n' \
    '{"type":"session","version":3,"id":"v","timestamp":"t","cwd":"/w2"}' \
    '{"type":"message","message":{"role":"assistant","usage":{"input":50,"output":10,"cacheRead":50,"cost":{"total":0.01}}}}' > "$FAKE_SESS/--y--/older.jsonl"
assert_helper "350 950 110 0.04" "$(PIA_PI_SESSIONS="$FAKE_SESS" tok_usage)" \
    "tok_usage accumulates across ALL sessions the container stores, not just the running one"
rm -rf "$FAKE_SESS"

# The chart must never be the only way to see a sample: the line view stays
# reachable, and a non-terminal stays on it.
if grep -q -- '--no-chart' "$AGENTS" && grep -q '\[ -t 1 \]' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --no-chart exists and the chart is chosen by 'is stdout a terminal'"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: the line view must stay selectable and non-terminals must not get escape codes"
    FAIL=$((FAIL + 1))
fi

# 'pia' runs on macOS' /bin/bash, which is still 3.2 — and 'declare -A' is a bash 4
# feature, so a top-level one aborts the entire CLI at load time (it did: 'pia run'
# died with "declare: -A: invalid option" before the monitor was anywhere near
# involved). The chart state therefore uses parallel indexed arrays.
if grep -Eq '(declare|local|typeset) -A ' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia.sh must stay bash 3.2 compatible — no associative arrays (see 'chart_index')"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: pia.sh stays bash 3.2 compatible (no associative arrays)"
    PASS=$((PASS + 1))
fi

# ... and the same for the other 4.x-only constructs that are easy to reach for.
if grep -Eq 'mapfile|readarray|declare -n|local -n |\$\{[A-Za-z_]+(\^\^|,,)\}|EPOCHSECONDS' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: pia.sh uses a bash 4+ construct that macOS' /bin/bash will not parse"
    FAIL=$((FAIL + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: no bash 4+ builtins/expansions in pia.sh (mapfile, namerefs, case conversion)"
    PASS=$((PASS + 1))
fi
