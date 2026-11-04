#!/bin/bash

# =============================================================================
# SECTION 18: --debug global flag tests
# =============================================================================
echo ""
echo -e "${YELLOW}=== SECTION 18: --debug global flag tests ===${NC}"

eval "$(sed -n '/^extract_name_and_options/,/^}/p' "$AGENTS")"

# --- extract_name_and_options: debug field (field 6) ---

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --debug my-container)
if [ "$(echo "$result" | cut -d'|' -f6)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets DEBUG_FLAG field with --debug"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DEBUG_FLAG field wrong (got '$(echo "$result" | cut -d'|' -f6)')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options -d my-container)
if [ "$(echo "$result" | cut -d'|' -f6)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets DEBUG_FLAG field with -d"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DEBUG_FLAG field wrong with -d (got '$(echo "$result" | cut -d'|' -f6)')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options my-container)
if [ "$(echo "$result" | cut -d'|' -f6)" = "" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options DEBUG_FLAG is empty without debug flag"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DEBUG_FLAG should be empty (got '$(echo "$result" | cut -d'|' -f6)')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options my-container --debug)
if [ "$(echo "$result" | cut -d'|' -f6)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets DEBUG_FLAG after name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DEBUG_FLAG after name (got '$(echo "$result" | cut -d'|' -f6)')"
    FAIL=$((FAIL + 1))
fi

result=$(MOUNT_DIR="" SSH_FLAG="" extract_name_and_options --debug my-container -m /tmp --ssh)
if [ "$(echo "$result" | cut -d'|' -f6)" = "yes" ] && [ "$(echo "$result" | cut -d'|' -f4)" = "/tmp" ] && [ "$(echo "$result" | cut -d'|' -f5)" = "yes" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: extract_name_and_options sets DEBUG_FLAG with other options"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: extract_name_and_options DEBUG_FLAG with other options (got '$result')"
    FAIL=$((FAIL + 1))
fi

# --- Global flag stripping: verify commands still work after --debug is stripped ---

# The 'run' tests below create real containers with these exact names —
# register them for cleanup.
register_test_container pia-test-debug-1 pia-test-debug-2 pia-test-debug-3 \
    pia-test-debug-8 pia-test-debug-9

# Test: --debug before subcommand is stripped
capture_output --debug run test-debug-1 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-1\|Starting agent"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug before 'run' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug before 'run' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug after subcommand is stripped
capture_output run --debug test-debug-2 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-2\|Starting agent"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug after 'run' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug after 'run' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: -d before subcommand is stripped
capture_output -d run test-debug-3 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-3\|Starting agent"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: -d before 'run' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: -d before 'run' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug with stop command is stripped
capture_output --debug stop test-debug-4 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-4\|does not exist"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug with 'stop' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug with 'stop' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug with rm command is stripped
capture_output --debug rm test-debug-5 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-5\|does not exist"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug with 'rm' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug with 'rm' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug with exec command is stripped
capture_output --debug exec test-debug-6 ls 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-6\|does not exist"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug with 'exec' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug with 'exec' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug with sh command is stripped
capture_output --debug sh test-debug-6b 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-6b\|does not exist"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug with 'sh' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug with 'sh' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug with monitor command is stripped
capture_output --debug monitor test-debug-6c 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-6c\|does not exist"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug with 'monitor' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug with 'monitor' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug with restart command is stripped
capture_output --debug restart test-debug-7 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-7\|does not exist"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug with 'restart' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug with 'restart' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug with ls command is stripped (ls doesn't need a name)
capture_output --debug ls 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "Pi Agent Containers:"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug with 'ls' is stripped, command still runs"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug with 'ls' should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: multiple --debug flags don't cause issues
capture_output --debug --debug run test-debug-8 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-8\|Starting agent"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: multiple --debug flags are handled gracefully"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: multiple --debug flags should be handled (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# Test: --debug in the middle of args
capture_output run --debug test-debug-9 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -q "test-debug-9\|Starting agent"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: --debug in middle of args is stripped"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: --debug in middle should be stripped (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

# --- log_cmd respects DEBUG_FLAG ---

echo ""
echo -e "${YELLOW}=== SECTION 19: log_cmd respects DEBUG_FLAG ===${NC}"

eval "$(sed -n '/^log_cmd/,/^}/p' "$AGENTS")"

# Without DEBUG_FLAG, log_cmd should produce no output
DEBUG_FLAG=""
output=$(log_cmd "docker run test" 2>&1)
if [ -z "$output" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: log_cmd produces no output when DEBUG_FLAG is empty"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: log_cmd should produce no output (got '$output')"
    FAIL=$((FAIL + 1))
fi

# With DEBUG_FLAG=yes, log_cmd should produce output
DEBUG_FLAG="yes"
output=$(log_cmd "docker run test" 2>&1)
if echo "$output" | grep -qF "[DEBUG] docker run test"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: log_cmd produces output when DEBUG_FLAG=yes"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: log_cmd should produce output (got '$output')"
    FAIL=$((FAIL + 1))
fi

# With DEBUG_FLAG=0, log_cmd should produce no output
DEBUG_FLAG="0"
output=$(log_cmd "docker run test" 2>&1)
if [ -z "$output" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: log_cmd produces no output when DEBUG_FLAG=0"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: log_cmd should produce no output (got '$output')"
    FAIL=$((FAIL + 1))
fi

# Reset DEBUG_FLAG
DEBUG_FLAG=""

# --- Help text includes --debug ---

echo ""
echo -e "${YELLOW}=== SECTION 20: Help text includes --debug ===${NC}"

capture_output --help 2>/dev/null || true
if echo "$CAPTURED_OUTPUT" | grep -qF -- "-d, --debug"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: help text includes -d, --debug option"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: help text should include --debug (output: $CAPTURED_OUTPUT)"
    FAIL=$((FAIL + 1))
fi

if echo "$CAPTURED_OUTPUT" | grep -qF "Global options"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: help text has 'Global options' section"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: help text should have 'Global options' section"
    FAIL=$((FAIL + 1))
fi

# --- DEBUG_FLAG preservation through cmd_run and cmd_restart ---

echo ""
echo -e "${YELLOW}=== SECTION 21: DEBUG_FLAG preserved through cmd_run and cmd_restart ===${NC}"

# Verify cmd_run uses ${DEBUG_FLAG:-...} pattern to preserve global value
if grep -q 'DEBUG_FLAG="${DEBUG_FLAG:-' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_run preserves global DEBUG_FLAG with ${DEBUG_FLAG:-...} pattern"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_run should preserve global DEBUG_FLAG"
    FAIL=$((FAIL + 1))
fi

# Verify cmd_restart uses ${DEBUG_FLAG:-...} pattern to preserve global value
if awk '/^cmd_restart/,/^}/' "$AGENTS" | grep -q 'DEBUG_FLAG="${DEBUG_FLAG:-'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_restart preserves global DEBUG_FLAG with ${DEBUG_FLAG:-...} pattern"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_restart should preserve global DEBUG_FLAG"
    FAIL=$((FAIL + 1))
fi

# Verify stop/rm/exec do NOT have their own debug_flag local variable
if ! awk '/^cmd_stop/,/^}/' "$AGENTS" | grep -q 'local debug_flag'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_stop does not have its own debug_flag (uses global)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_stop should not have its own debug_flag"
    FAIL=$((FAIL + 1))
fi

if ! awk '/^cmd_rm/,/^}/' "$AGENTS" | grep -q 'local debug_flag'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_rm does not have its own debug_flag (uses global)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_rm should not have its own debug_flag"
    FAIL=$((FAIL + 1))
fi

if ! awk '/^cmd_exec/,/^}/' "$AGENTS" | grep -q 'local debug_flag'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_exec does not have its own debug_flag (uses global)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_exec should not have its own debug_flag"
    FAIL=$((FAIL + 1))
fi

if ! awk '/^cmd_sh/,/^}/' "$AGENTS" | grep -q 'local debug_flag'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_sh does not have its own debug_flag (uses global)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_sh should not have its own debug_flag"
    FAIL=$((FAIL + 1))
fi

if ! awk '/^cmd_clean/,/^}/' "$AGENTS" | grep -q 'local debug_flag'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_clean does not have its own debug_flag (uses global)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_clean should not have its own debug_flag"
    FAIL=$((FAIL + 1))
fi

if ! awk '/^cmd_resume/,/^}/' "$AGENTS" | grep -q 'local debug_flag'; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: cmd_resume does not have its own debug_flag (uses global)"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: cmd_resume should not have its own debug_flag"
    FAIL=$((FAIL + 1))
fi

# Verify the MAIN section strips global flags before dispatching
if grep -q 'CLEAN_ARGS=' "$AGENTS"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: MAIN section strips global flags via CLEAN_ARGS"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: MAIN section should strip global flags"
    FAIL=$((FAIL + 1))
fi
