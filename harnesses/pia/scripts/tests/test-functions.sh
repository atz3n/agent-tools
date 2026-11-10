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

# Test DOCKER_FLAG (field 7) is set with --docker
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --docker my-container)
if [ "$(echo "$result" | cut -d'|' -f7)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets DOCKER_FLAG field (field 7) with --docker"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DOCKER_FLAG field wrong (got '$(echo "$result" | cut -d'|' -f7)')"
    FAIL=$((FAIL + 1))
fi

# Test DOCKER_FLAG is empty when no --docker flag
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options my-container)
if [ "$(echo "$result" | cut -d'|' -f7)" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options DOCKER_FLAG is empty without --docker"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DOCKER_FLAG should be empty (got '$(echo "$result" | cut -d'|' -f7)')"
    FAIL=$((FAIL + 1))
fi

# Test --docker combined with -m and --ssh
result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -m /tmp my-container --ssh --docker)
if [ "$(extract_name_only "$result")" = "my-container" ] && [ "$(echo "$result" | cut -d'|' -f4)" = "/tmp" ] && [ "$(echo "$result" | cut -d'|' -f5)" = "yes" ] && [ "$(echo "$result" | cut -d'|' -f7)" = "yes" ]; then
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

# --- Docker socket tests (opt-in --docker) ---

# Test Docker socket is NOT included without --docker flag
MOUNT_DIR="" SSH_FLAG="" DOCKER_FLAG=""
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

# Test Docker socket is included when --docker is set and socket exists
DOCKER_SOCK="/tmp/test-docker-sock-$$"
if start_test_socket "$DOCKER_SOCK"; then
    MOUNT_DIR="" SSH_FLAG="" DOCKER_FLAG="yes"
    result=$(DOCKER_SOCKET="$DOCKER_SOCK" build_docker_args "test-container" 2>/dev/null)
    if echo "$result" | grep -qF "$DOCKER_SOCK:/var/run/docker.sock"; then
        TOTAL=$((TOTAL + 1))
        echo -e "  ${GREEN}PASS${NC}: build_docker_args includes Docker socket with --docker"
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

# Test warning when --docker is set but socket does not exist
MOUNT_DIR="" SSH_FLAG="" DOCKER_FLAG="yes"
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
# The key fix: cmd_run uses 'docker start -i' (not 'docker run -i')
# when restarting a stopped container.
if grep -q 'docker start -i' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_run uses 'docker start -i' to restart stopped container"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_run should use 'docker start -i' for stopped containers"
    FAIL=$((FAIL + 1))
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
MOUNT_DIR="" SSH_FLAG="" DOCKER_FLAG=""
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

if grep -q 'done < <(pia_ps)' "$AGENTS" && grep -q 'pia_ps --filter "status=exited"' "$AGENTS"; then
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
