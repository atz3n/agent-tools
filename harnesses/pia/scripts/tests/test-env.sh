#!/bin/bash

# =============================================================================
# SECTION: The '-e/--env' option — parser, arg building, and end-to-end
# Section name for the filter: 'env'. The end-to-end part needs the pia
# image and a live Docker daemon; it is skipped (loudly) without them.
# =============================================================================
if should_run_section "env"; then
echo ""
echo -e "${YELLOW}=== SECTION: The '-e/--env' option ===${NC}"

# -- parser level (no Docker needed) -----------------------------------------

capture_output run -e 9BAD=x
assert_exit_code 1 "$CAPTURED_EXIT" "run -e with invalid name should exit 1"
assert_output_contains "Invalid environment variable name" "$CAPTURED_OUTPUT" "Should reject invalid env name"

capture_output run --env
assert_exit_code 1 "$CAPTURED_EXIT" "run --env without value should exit 1"
assert_output_contains "requires a value" "$CAPTURED_OUTPUT" "Should reject missing --env value"

capture_output run --help
assert_output_contains "--env" "$CAPTURED_OUTPUT" "run --help should document --env"

# Unit: extract_name_and_options puts the fields on line 1 and the env specs
# on the lines after, without eating the container name.
eval "$(sed -n '/^log_error()/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^extract_name_and_options/,/^}/p' "$AGENTS")"

ENV_PARSE_OUT="$(extract_name_and_options mail -e FOO=bar --env BAZ -s)"
ENV_PARSE_FIELDS="$(printf '%s\n' "$ENV_PARSE_OUT" | head -1)"
ENV_PARSE_SPECS="$(printf '%s\n' "$ENV_PARSE_OUT" | tail -n +2)"
assert_output_contains "mail|0|0||yes" "$ENV_PARSE_FIELDS" "extract keeps fields on line 1 with the name"
assert_output_contains "FOO=bar" "$ENV_PARSE_SPECS" "extract returns -e spec as an extra line"
assert_output_contains "BAZ" "$ENV_PARSE_SPECS" "extract returns --env pass-through spec too"

# Unit: build_docker_args emits '-e <spec>' per spec, before the image name.
eval "$(sed -n '/^IMAGE_NAME=/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^config_hash/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^project_labels/,/^}/p' "$AGENTS")"
eval "$(sed -n '/^build_docker_args/,/^}/p' "$AGENTS")"

MOUNT_DIR="" SSH_FLAG="" DOCKER_MODE=""
ENV_ARGS_OUT="$(ENV_SPECS="$(printf 'FOO=bar\nBAZ')" && build_docker_args "pia-envargs")"
if echo "$ENV_ARGS_OUT" | grep -qx -- "-e" && \
   echo "$ENV_ARGS_OUT" | grep -qx "FOO=bar" && \
   echo "$ENV_ARGS_OUT" | grep -qx "BAZ"; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: build_docker_args emits -e for every spec"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: build_docker_args missing -e args (got '$ENV_ARGS_OUT')"
    FAIL=$((FAIL + 1))
fi

if [ "$(echo "$ENV_ARGS_OUT" | grep -n "FOO=bar" | cut -d: -f1)" -lt \
     "$(echo "$ENV_ARGS_OUT" | grep -nx "$IMAGE_NAME" | cut -d: -f1)" ]; then
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: -e args come before the image name"
    PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: -e args must precede the image name (got '$ENV_ARGS_OUT')"
    FAIL=$((FAIL + 1))
fi

# -- end-to-end (Docker) ------------------------------------------------------

if ! docker image inspect pia > /dev/null 2>&1; then
    echo -e "  ${YELLOW}SKIP${NC}: pia image not built — env end-to-end tests skipped"
else
    ENV_TEST="pia-test-env"
    register_test_container "$ENV_TEST"

    # timeout kills the attaching client mid-session, leaving the container
    # running for the exec checks (same pattern as the run/stop tests).
    timeout 10 bash "$AGENTS" run "$ENV_TEST" -e PIA_TEST_ENV=hello < /dev/null > /dev/null 2>&1 || true

    ENV_EXEC=$(timeout 5 bash "$AGENTS" exec "$ENV_TEST" printenv PIA_TEST_ENV < /dev/null 2>&1) || true
    assert_output_contains "hello" "$ENV_EXEC" "container environment carries PIA_TEST_ENV=hello"

    # Host pass-through: '-e NAME' (no value) forwards the host's value.
    ENV_PT="pia-test-env-pt"
    register_test_container "$ENV_PT"
    PIA_TEST_PASSTHRU=fromhost timeout 10 bash "$AGENTS" create "$ENV_PT" -e PIA_TEST_PASSTHRU < /dev/null > /dev/null 2>&1 || true
    PT_VAL=$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ENV_PT" 2>/dev/null | grep '^PIA_TEST_PASSTHRU=' || true)
    assert_output_contains "fromhost" "$PT_VAL" "bare -e forwards the host value"

    # Recreate (forced by the --ssh flag change) without -e carries the env.
    # The timeout kills the attaching client mid-session and pia stops the
    # container with it — 'docker start' revives the idle entrypoint so the
    # exec checks see the NEW container config, not a stopped container.
    timeout 15 bash "$AGENTS" restart "$ENV_TEST" --ssh < /dev/null > /dev/null 2>&1 || true
    docker start "$ENV_TEST" > /dev/null 2>&1 || true
    INH_EXEC=$(timeout 5 bash "$AGENTS" exec "$ENV_TEST" printenv PIA_TEST_ENV < /dev/null 2>&1) || true
    assert_output_contains "hello" "$INH_EXEC" "recreate without -e carries the env over"

    # A changed value contradicts the container config → recreate with it.
    timeout 15 bash "$AGENTS" restart "$ENV_TEST" -e PIA_TEST_ENV=changed < /dev/null > /dev/null 2>&1 || true
    docker start "$ENV_TEST" > /dev/null 2>&1 || true
    CHG_EXEC=$(timeout 5 bash "$AGENTS" exec "$ENV_TEST" printenv PIA_TEST_ENV < /dev/null 2>&1) || true
    assert_output_contains "changed" "$CHG_EXEC" "changed -e value recreates with the new value"

    timeout 10 bash "$AGENTS" remove "$ENV_TEST" < /dev/null > /dev/null 2>&1 || true
    timeout 10 bash "$AGENTS" remove "$ENV_PT" < /dev/null > /dev/null 2>&1 || true
fi
fi
