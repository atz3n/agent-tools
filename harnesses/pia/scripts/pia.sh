#!/bin/bash
set -euo pipefail

# Multi-instance Pi Agent Container Manager
#
# Manage multiple pi agent Docker containers in parallel with named instances.
#
# Usage:
#   pia run  [NAME] [OPTIONS]  Start a new agent container
#   pia create [NAME] [OPTIONS] Create a stopped agent container without starting it
#   pia stop  [NAME]            Stop a named container
#   pia remove [NAME]           Remove a named container
#   pia rm    [NAME]            Alias for remove
#   pia list                      List all agent containers
#   pia ls                        Alias for list
#   pia clean                     Remove all stopped agent containers (except kept pia-keep-*)
#   pia resume                    Start the most recently stopped agent container and continue its last pi session
#   pia rs                        Alias for resume
#   pia restart [NAME] [OPTIONS] Restart a named container
#   pia ask   [NAME] [PROMPT]   Run a one-shot non-interactive pi prompt (pi --print)
#   pia exec    [NAME] [CMD]    Execute a command in a running container
#   pia sh      [NAME]          Open an interactive bash shell in a running container
#   pia monitor [NAME]          Live view: request destinations + CPU/mem/net
#   pia urls  [NAME]            Every URL/destination called since the container was created
#   pia keep    [NAME] [SUFFIX] Protect a container from 'pia clean' (rename to pia-keep-*)
#   pia unkeep  [NAME]          Remove the keep protection (rename back to pia-*)
#   pia rename  [NAME] [NEW]    Rename a container
#
# If NAME is omitted, a random name is generated (pia-XXXXXXXX).
#
# Every container is stamped with the project label com.docker.compose.project=pia
# (plain 'docker run --label', compose is never called), so Docker groups all
# agent instances under a single 'pia' project — visible in 'docker compose ls',
# in Docker Desktop, and via 'docker ps --filter label=...'.
#
# Global options (any command):
#   -d, --debug        Show debug output (docker commands)
#
# Command options (run/create/restart):
#   -m, --mount <dir>  Mount the specified directory into /workspace
#   -s, --ssh          Mount the host SSH agent socket into the container
#       --docker       Mount the host Docker socket into the container (opt-in;
#                      gives the container root-equivalent access to the host)
#   -o, --openrouter   Forward the host OpenRouter API key into the container
#                      (opt-in; without it the container starts with no key)
#   -h, --help         Display this help message
#
# Command options (monitor):
#   -i, --interval <sec>  Seconds per resource sample (default: 3)
#       --raw             Stream destinations continuously, no resource summary
#
# Command options (urls):
#   -a, --all             Every logged request in order, no aggregation
#
# Examples:
#   pia run                  # Start with auto-generated name
#   pia run my-project       # Start with custom name
#   pia run -m /path/to/proj # Start with mount, auto name
#   pia run proj -m . --ssh  # Start with name, mount, and SSH
#   pia run proj --docker    # Start with host Docker socket available
#   pia run proj -o           # Start with the OpenRouter key forwarded
#   pia create proj -m /path # Create stopped container for a later 'pia ask'
#   pia --debug run proj     # Show debug output (global flag)
#   pia list                   # List all containers
#   pia stop my-project        # Stop named container
#   pia remove my-project      # Remove named container
#   pia restart my-project -m . # Restart with mount
#   pia exec my-project ls /   # Run command in container
#   pia sh my-project           # Open a bash shell inside the container
#   pia monitor                 # Watch destinations + CPU/mem/net of the only running container
#   pia urls                    # Destinations called since creation (aggregated)
#   pia urls proj --all         # Every logged request of 'proj', in order

###################################################################################################
# CONFIGURATION
###################################################################################################

IMAGE_NAME="pia"
PREFIX="pia-"
KEEP_PREFIX="pia-keep-"   # kept containers (pia-keep-*) are protected from 'pia clean'
RANDOM_SUFFIX_LENGTH=8
PROJECT_NAME="pia"        # project every pia container belongs to (label value)
MONITOR_CYCLE_SECONDS="3"  # default sample length for 'pia monitor' (see cmd_monitor)
MONITOR_RAW_CHUNK="5"      # default capture chunk for 'pia monitor --raw'; '-i' overrides it


###################################################################################################
# HELPERS
###################################################################################################

generate_random_name() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local name="${PREFIX}"
    for i in $(seq 1 $RANDOM_SUFFIX_LENGTH); do
        name+="${chars:RANDOM%${#chars}:1}"
    done
    echo "$name"
}

log_info() {
    echo "[INFO] $*"
}

# Short hash for the project 'config-hash' label — project views ignore
# containers without it, so every instance gets a fresh one.
config_hash() {
    local input="${1}|${RANDOM}|$(date +%s%N 2>/dev/null || date +%s)"
    if command -v sha256sum > /dev/null 2>&1; then
        printf '%s' "$input" | sha256sum | cut -c1-40
    elif command -v shasum > /dev/null 2>&1; then
        printf '%s' "$input" | shasum -a 256 | cut -c1-40
    else
        printf '%s' "$input" | cksum | tr ' ' '-'
    fi
}

# Project labels that put a container in the 'pia' project, one argument per
# line (consumed by build_docker_args). They are applied with plain
# 'docker create/run --label'; compose is neither installed for nor called by pia.
# 'com.docker.compose.project' is simply the label Docker, 'docker compose ls'
# and Docker Desktop read as a project name — the same one the tasks-server
# containers carry — so the pia instances group the same way.
project_labels() {
    local name="$1"
    local service hash

    # Instance name, shown as the project's service; may only use [a-zA-Z0-9._-]
    service="${name#${PREFIX}}"
    service="${service//[^a-zA-Z0-9._-]/-}"
    [ -n "$service" ] || service="instance"

    hash="$(config_hash "$name")"

    echo "--label"
    echo "com.docker.compose.project=${PROJECT_NAME}"
    echo "--label"
    echo "com.docker.compose.service=${service}"
    echo "--label"
    echo "com.docker.compose.oneoff=False"
    echo "--label"
    echo "com.docker.compose.config-hash=${hash}"
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

# List pia containers as 'id<TAB>name<TAB>status<TAB>created'.
# Matches both the name prefix and the project label, so containers created
# before the labels existed (or outside the CLI) are found too.
# Extra arguments are passed to 'docker ps' as additional filters.
# NOTE: 'docker ps' orders by creation time, NOT by stop time — never use
# 'head -1' here to find "the latest stopped" container, use pia_last_stopped.
pia_ps() {
    local fmt='{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.CreatedAt}}'
    {
        docker ps -a --filter "name=^${PREFIX}" --format "$fmt" "$@" 2>/dev/null
        docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "$fmt" "$@" 2>/dev/null
    } | awk -F'\t' '!seen[$1]++'
}

# Print the name of the most recently *stopped* agent container (empty if
# none). 'docker ps' sorts by creation time, so the newest-created container
# is not necessarily the one that stopped last — the real stop time comes
# from State.FinishedAt, which only 'docker inspect' exposes.
pia_last_stopped() {
    local ids
    ids=$(pia_ps --filter "status=exited" | cut -f1)
    [ -n "$ids" ] || return 0

    docker inspect --format $'{{.State.FinishedAt}}\t{{.Name}}' $ids 2>/dev/null | awk -F'\t' '{
        ts = $1; sub(/Z$/, "", ts)
        name = $2; sub(/^\//, "", name)
        frac = ""
        if (ts ~ /\./) { frac = ts; sub(/^[^.]*\./, "", frac); sub(/\..*$/, "", ts) }
        # zero-pad the (variable-length) nanosecond fraction so a plain
        # string sort orders the timestamps correctly
        printf "%s\t%s\t%s\n", ts, substr(frac "000000000", 1, 9), name
    }' | sort -t$'\t' -k1,1 -k2,2 | tail -1 | cut -f3
}

# Print a docker command in grey for visibility
log_cmd() {
    if [ "${DEBUG_FLAG:-}" = "yes" ]; then
        tput setaf 8
        printf '[DEBUG] %s\n' "$*"
        tput sgr0
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <COMMAND> [ARGS]

Multi-instance Pi Agent Container Manager.

Commands:
  run [NAME] [OPTIONS]     Start a new agent container
  create [NAME] [OPTIONS]  Create a stopped agent container without starting it
  stop  [NAME]               Stop a named container
  remove [NAME]              Remove a named container
  rm    [NAME]               Alias for remove
  list                       List all agent containers
  ls                         Alias for list
  clean                      Remove all stopped agent containers (except kept pia-keep-*)
  resume                     Start the most recently stopped agent container and continue its last pi session
                             (takes no NAME — use 'run <NAME>' to continue a specific container)
  rs                         Alias for resume
  restart [NAME] [OPTIONS]   Restart a named container
  ask     [NAME] [PROMPT]    One-shot non-interactive pi prompt (pi --print); omit NAME if ephemeral
  exec    [NAME] [CMD]       Execute a command in a running container
  sh      [NAME]             Open an interactive bash shell in a running container (alias: shell)
                             (NAME may be omitted when exactly one container is running)
  monitor [NAME] [OPTIONS]   Live view of a running container: where its requests go
                             (TLS SNI / cleartext HTTP URLs) + CPU, memory, net I/O
                             (terminal only, nothing is logged; Ctrl-C to stop)
  urls    [NAME] [OPTIONS]   Every destination (TLS SNI) and cleartext HTTP URL the
                             container has called since it was created, with counts
                             (read from the container's own request log)
  keep    [NAME] [SUFFIX]    Protect a container from 'pia clean' (rename to pia-keep-*)
  unkeep  [NAME]             Remove the keep protection (rename back to pia-*)
  rename  [NAME] [NEW]       Rename a container

If NAME is omitted, a random name is generated (pia-XXXXXXXX).

All containers are labelled with the project 'pia' (com.docker.compose.project=pia),
so Docker groups them together — like the tasks-server containers. The labels are
applied with plain 'docker create/run --label'; compose is never called and no
compose file is used.

Global options (any command):
  -d, --debug        Show debug output (docker commands)

Command options (run/create/restart):
  -m, --mount <dir>  Mount the specified directory into /workspace
  -s, --ssh          Mount the host SSH agent socket into the container
      --docker       Mount the host Docker socket into the container (opt-in;
                     gives the container root-equivalent access to the host)
  -o, --openrouter   Forward the host OpenRouter API key into the container
                     (opt-in; without it the container starts with no key,
                     even when OPENROUTER_API_KEY is set on the host)
  -h, --help         Display this help message

Command options (monitor):
  -i, --interval <sec>  Seconds per resource sample (default: 3)
      --raw             Stream destinations continuously, no resource summary

Command options (urls):
  -a, --all             Every logged request in order, no aggregation
  -h, --help            Display help message

Examples:
  $(basename "$0") run                  # Start with auto-generated name
  $(basename "$0") run my-project       # Start with custom name
  $(basename "$0") run -m /path/to/proj # Start with mount, auto name
  $(basename "$0") run proj -m . --ssh  # Start with name, mount, and SSH
  $(basename "$0") run proj --docker    # Start with host Docker socket available
  $(basename "$0") run proj -o          # Start with the OpenRouter key forwarded
  $(basename "$0") create proj -m /path # Create stopped container for a later 'pia ask'
  $(basename "$0") --debug run proj     # Show debug output (global flag)
  $(basename "$0") list                   # List all containers
  $(basename "$0") ls                     # Alias for list
  $(basename "$0") stop my-project        # Stop named container
  $(basename "$0") remove my-project      # Remove named container
  $(basename "$0") rm my-project          # Alias for remove
  $(basename "$0") clean                  # Remove all stopped containers
  $(basename "$0") resume                 # Start the most recently stopped container, continue its last session
  $(basename "$0") rs                     # Alias for resume
  $(basename "$0") restart my-project -m . # Restart with mount
  $(basename "$0") exec my-project ls /   # Run command in container
  $(basename "$0") sh my-project          # Open a bash shell in the container
  $(basename "$0") sh                     # Shell in the only running container
  $(basename "$0") monitor                 # Watch the only running container (3s cycles)
  $(basename "$0") monitor proj -i 10      # Watch 'proj' with 10s resource samples
  $(basename "$0") monitor proj --raw      # Just the destination lines, no summaries
  $(basename "$0") urls                    # What has the only running container called?
  $(basename "$0") urls proj --all         # Every logged request of 'proj', in order
  $(basename "$0") ask my-project List the open tasks   # One-shot pi prompt
  $(basename "$0") keep my-project         # Protect from 'pia clean' (→ pia-keep-my-project)
  $(basename "$0") keep zzz my-session     # Keep with explicit name (→ pia-keep-my-session)
  $(basename "$0") unkeep my-project       # Remove protection (→ pia-my-project)
  $(basename "$0") rename old-name new-name # Rename a container
EOF
}

# Extract name and options from args.
# Args can be in any order: name and options can be interleaved.
# The first non-option, non-flag-value arg is treated as the name.
# If no non-option arg exists, name is empty (auto-generated).
# Outputs: NAME|HELP_REQUESTED|INVALID_OPTION|MOUNT_DIR|SSH_FLAG|DEBUG_FLAG|DOCKER_FLAG|MISSING_VALUE|OPENROUTER_FLAG
extract_name_and_options() {
    local name=""
    local in_mount_value=0
    local help_requested=0
    local invalid_option=0
    local mount_dir=""
    local ssh_flag=""
    local debug_flag=""
    local docker_flag=""
    local openrouter_flag=""
    local missing_value=0

    for arg in "$@"; do
        # If we're in a -m/--mount value, capture it
        if [ "$in_mount_value" -eq 1 ]; then
            mount_dir="$arg"
            in_mount_value=0
            continue
        fi

        case "$arg" in
            -m|--mount)
                # Next arg is the mount dir — capture it now
                in_mount_value=1
                ;;
            -s|--ssh)
                ssh_flag="yes"
                ;;
            --docker)
                docker_flag="yes"
                ;;
            -o|--openrouter)
                openrouter_flag="yes"
                ;;
            -h|--help)
                help_requested=1
                ;;
            -d|--debug)
                debug_flag="yes"
                ;;
            -*)
                # Unknown option — single-letter flags like -m/-s/-h/-t are recognized;
                # any other single dash-letter is an unknown option (not a name).
                # Long options (--*) are always options.
                if [[ "$arg" == --* ]] || [[ "$arg" =~ ^-[a-z]$ ]]; then
                    invalid_option=1
                elif [ -z "$name" ]; then
                    name="$arg"
                else
                    invalid_option=1
                fi
                ;;
            *)
                # Positional arg — first one is the name
                if [ -z "$name" ]; then
                    name="$arg"
                fi
                ;;
        esac
    done

    # '--mount' was the last argument with no value. This is an error, not a
    # warning: continuing would silently create a container without the mount
    # the caller asked for (and with a random name if none was given).
    if [ "$in_mount_value" -eq 1 ]; then
        log_error "Option '--mount' requires a value."
        missing_value=1
    fi

    echo "${name}|${help_requested}|${invalid_option}|${mount_dir:-}|${ssh_flag:-}|${debug_flag:-}|${docker_flag:-}|${missing_value}|${openrouter_flag:-}"
}

# Locate the OpenRouter key file ('openrouter-key.txt'), printing one path or
# nothing when no file exists. Search order:
#   1. $PIA_OPENROUTER_KEY_FILE          — explicit override
#   2. ~/.pia/secrets/openrouter-key.txt — the standard location, created by
#      'install-pia.sh' and filled in by the user (see the README).
#      pia is always run from the installed location, so this folder is the
#      only place it looks besides the override above.
# An override that is set but missing is a hard error (return 1): the caller
# asked for one specific key file, so falling back to a different key would
# be a silent credential swap — abort instead.
openrouter_key_file() {
    local candidate
    if [ -n "${PIA_OPENROUTER_KEY_FILE:-}" ]; then
        if [ ! -f "${PIA_OPENROUTER_KEY_FILE}" ]; then
            log_error "PIA_OPENROUTER_KEY_FILE is set to '${PIA_OPENROUTER_KEY_FILE}' but no such file exists."
            return 1
        fi
        echo "$PIA_OPENROUTER_KEY_FILE"
        return 0
    fi
    candidate="${HOME}/.pia/secrets/openrouter-key.txt"
    if [ -f "$candidate" ]; then
        echo "$candidate"
    fi
}

# Resolve the OpenRouter API key in the CURRENT shell and export it — but
# ONLY when the caller opted in with '--openrouter' (OPENROUTER_FLAG). By
# default the key is never forwarded, even when OPENROUTER_API_KEY is
# exported on the host: containers should not carry credentials they do not
# use (e.g. when inference runs against a local model). Pi has
# OpenRouter as a built-in provider, so the key in the environment is all it
# takes — no models.json entry needed; 'pi' then lists the key's models under
# 'openrouter/...' in /model. Priority: an exported OPENROUTER_API_KEY, then
# an 'openrouter-key.txt' file (see openrouter_key_file).
# This MUST run in the main shell, right before docker is called: build_docker_args
# is consumed through a process substitution, and docker takes the value of a
# name-only '-e VAR' from the environment of the 'docker run' process — an
# export made inside that subshell would be gone before docker starts.
resolve_openrouter_key() {
    # Opt-in only — without '--openrouter' nothing is resolved, exported or
    # forwarded, no matter what the host environment holds.
    [ -n "${OPENROUTER_FLAG:-}" ] || return 0
    [ -n "${OPENROUTER_API_KEY:-}" ] && return 0
    local key_file key
    # A broken PIA_OPENROUTER_KEY_FILE override (log_error already printed by
    # openrouter_key_file) aborts the whole command — 'exit' works here
    # because resolve runs in the MAIN shell, right before docker is called.
    if ! key_file="$(openrouter_key_file)"; then
        exit 1
    fi
    # 'return 0', not a bare 'return': a bare return would propagate the failed
    # [ -n ] status (1) and, under 'set -e', abort the caller (cmd_run etc.)
    # when no key file exists — which is the normal case.
    if [ -z "$key_file" ]; then
        log_warn "--openrouter requested but no OpenRouter key found — container starts without it."
        return 0
    fi
    key="$(tr -d ' \t\r\n' < "$key_file" 2>/dev/null)" || key=''
    if [ -n "$key" ]; then
        OPENROUTER_API_KEY="$key"
        export OPENROUTER_API_KEY
    else
        log_warn "OpenRouter key file '${key_file}' is empty — key not forwarded."
    fi
}

# Build docker run arguments shared between run and restart
# Outputs one argument per line for safe reassembly by callers
build_docker_args() {
    local name="$1"

    echo "--name"
    echo "$name"

    # Group the container under the 'pia' project (label only, no compose)
    local label
    while IFS= read -r label; do
        echo "$label"
    done < <(project_labels "$name")

    # SSH agent socket
    if [ -n "$SSH_FLAG" ]; then
        if [ -n "${SSH_AUTH_SOCK}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
            echo "-v"
            echo "${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock"
            printf '%s\n' "-e"
            echo "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
        else
            log_warn "SSH_AUTH_SOCK is not set or socket not found — SSH agent is not available."
        fi
    fi

    # OpenRouter API key — only forwarded when the caller opted in with
    # '--openrouter' (OPENROUTER_FLAG); by default the container gets no key,
    # even when OPENROUTER_API_KEY is exported on the host. When opted in,
    # callers run resolve_openrouter_key in the main shell first
    # (see its comment); an export here would not survive the process
    # substitution this function is read from. The variable is passed to
    # docker by NAME only (no '=value') so the key itself never appears in
    # the 'docker run' command line that 'ps' and the debug log show; docker
    # reads the value from pia's environment. Without a resolved key no '-e'
    # is emitted and pi simply starts without the OpenRouter credential.
    if [ -n "${OPENROUTER_FLAG:-}" ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
        printf '%s\n' "-e" "OPENROUTER_API_KEY"
    fi

    # Mount directory
    if [ -n "$MOUNT_DIR" ]; then
        if [ ! -d "$MOUNT_DIR" ]; then
            log_error "Mount directory '${MOUNT_DIR}' does not exist."
            exit 1
        fi
        echo "-v"
        echo "$(cd "${MOUNT_DIR}" && pwd):/workspace"
        echo "-w"
        echo "/workspace"
    fi

    # Docker socket (opt-in) — lets the in-container docker CLI talk to the
    # host daemon. Root-equivalent on the host, hence opt-in only.
    if [ -n "${DOCKER_FLAG:-}" ]; then
        local docker_socket="${DOCKER_SOCKET:-/var/run/docker.sock}"
        if [ -S "$docker_socket" ]; then
            echo "-v"
            echo "${docker_socket}:/var/run/docker.sock"
        else
            log_warn "Docker socket '${docker_socket}' not found — Docker is not available in the container."
        fi
    fi

    echo "$IMAGE_NAME"
}

# Check if a container exists (running or stopped)
container_exists() {
    docker container inspect "$1" > /dev/null 2>&1
}

# Check if a container is running
container_is_running() {
    docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q "true"
}

# Resolve a container name to its ID. Sessions pin to the ID so that a
# 'pia rename'/'pia keep' during a live session cannot orphan the container
# when the session ends and the container is stopped again.
container_id() {
    docker container inspect -f '{{.Id}}' "$1" 2>/dev/null
}

# Add the keep marker to a (prefixed) name: pia-zzz -> pia-keep-zzz.
# Idempotent: names that are already kept are returned unchanged.
add_keep() {
    local name="$1"
    if [[ "$name" == ${KEEP_PREFIX}* ]]; then
        echo "$name"
    else
        echo "${KEEP_PREFIX}${name#${PREFIX}}"
    fi
}

# Strip the keep marker from a name: pia-keep-zzz -> pia-zzz.
# Names without the keep marker are returned unchanged.
strip_keep() {
    local name="$1"
    if [[ "$name" == ${KEEP_PREFIX}* ]]; then
        echo "${PREFIX}${name#${KEEP_PREFIX}}"
    else
        echo "$name"
    fi
}

# Normalize a keep target suffix into a full keep name:
#   foo        -> pia-keep-foo
#   pia-foo    -> pia-keep-foo
#   pia-keep-foo -> pia-keep-foo (already a keep name)
to_keep_name() {
    local target="$1"
    if [[ "$target" == ${KEEP_PREFIX}* ]]; then
        echo "$target"
        return
    fi
    echo "${KEEP_PREFIX}${target#${PREFIX}}"
}


# Wait until a container reports running (short grace after 'docker run -d').
wait_running() {
    local name="$1" i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        container_is_running "$name" && return 0
        sleep 0.2
    done
    return 1
}

# Pick 'docker exec' args: real TTY when we have one, plain stdin otherwise.
# Note: meant to be used via command substitution, so fd 1 is a pipe here —
# probe stdin (fd 0) and stderr (fd 2), which both survive the subshell.
exec_tty_args() {
    if [ -t 0 ] && [ -t 2 ]; then
        echo "-it"
    else
        echo "-i"
    fi
}

# Start a fresh pi session in a newly created container and stop the
# container when the session ends (matching the old 'ENTRYPOINT pi' lifecycle
# where the container exited together with pi).
start_session() {
    local name="$1"

    # Pin the session to the container ID: the container may be renamed
    # ('pia rename', 'pia keep') while pi runs, and the stop below must still
    # find it when the session ends.
    local id
    id="$(container_id "$name")"
    if [ -z "$id" ]; then
        log_error "Container '${name}' does not exist."
        return 1
    fi

    if ! wait_running "$id"; then
        log_warn "Container '${name}' did not report running — trying to attach anyway."
    fi

    local exec_args
    exec_args="$(exec_tty_args)"
    log_cmd "docker exec ${exec_args} ${name} pi"
    local rc=0
    docker exec ${exec_args} "$id" pi || rc=$?

    if container_is_running "$id"; then
        log_cmd "docker stop ${name}"
        docker stop "$id" > /dev/null 2>&1
    fi

    return $rc
}

# Start a stopped container and drop into pi, continuing its last session.
#
# The container is started detached and pi is attached via 'docker exec -it'
# so it gets a real TTY and can be launched with '--continue' — 'docker start'
# cannot pass arguments to the entrypoint. When the session ends the container
# is stopped again, matching the previous 'pi exits, container exits' behavior.
# Only images with the idling entrypoint are supported; containers built from
# older images (ENTRYPOINT ['pi']) cannot host an exec'd session — remove them
# and re-create them from the current image.
attach_session() {
    local name="$1"

    log_cmd "docker start ${name}"
    if ! docker start "$name" > /dev/null 2>&1; then
        log_error "Failed to start container '${name}'."
        exit 1
    fi

    # Pin the session to the container ID: the container may be renamed
    # ('pia rename', 'pia keep') while pi runs, and the stop below must still
    # find it when the session ends.
    local id
    id="$(container_id "$name")"
    if [ -z "$id" ]; then
        log_error "Container '${name}' disappeared after starting."
        exit 1
    fi

    local exec_args
    exec_args="$(exec_tty_args)"

    log_cmd "docker exec ${exec_args} ${name} pi --continue"
    local rc=0
    docker exec ${exec_args} "$id" pi --continue || rc=$?

    # Session ended — stop the container, as when pi used to be the entrypoint.
    # Exit codes 125-127 mean the exec itself could not run pi; leave the
    # container running in that case so nothing is lost.
    case "$rc" in
        125|126|127) ;;
        *)
            if container_is_running "$id"; then
                log_cmd "docker stop ${name}"
                docker stop "$id" > /dev/null 2>&1
            fi
            ;;
    esac

    return $rc
}

###################################################################################################
# COMMANDS
###################################################################################################

# Ensure a name has the PREFIX, adding it if missing
ensure_prefix() {
    local name="$1"
    if [ -n "$name" ] && [[ "$name" != ${PREFIX}* ]]; then
        name="${PREFIX}${name}"
    fi
    echo "$name"
}

# Rename a container. Verifies the source exists and the target name is free.
# Works on running and stopped containers.
do_rename() {
    local old="$1" new="$2"

    if [ "$old" = "$new" ]; then
        log_info "Container '${old}' already has that name."
        return 0
    fi

    if ! container_exists "$old"; then
        log_error "Container '${old}' does not exist."
        exit 1
    fi

    if container_exists "$new"; then
        log_error "Container '${new}' already exists."
        exit 1
    fi

    log_info "Renaming container '${old}' to '${new}'..."
    log_cmd "docker rename ${old} ${new}"
    if docker rename "$old" "$new"; then
        log_info "Container renamed to '${new}'."
    else
        log_error "Failed to rename container '${old}' to '${new}'."
        exit 1
    fi
}

# Create a container without starting it (same options as 'run').
# The stopped container can be started later with 'pia run <NAME>' or used
# directly with 'pia ask <NAME> <PROMPT>', which starts it on demand.
cmd_create() {
    local name help_req invalid_opt
    local result
    result="$(extract_name_and_options "$@")"
    name="$(echo "$result" | cut -d'|' -f1)"
    help_req="$(echo "$result" | cut -d'|' -f2)"
    invalid_opt="$(echo "$result" | cut -d'|' -f3)"
    MOUNT_DIR="$(echo "$result" | cut -d'|' -f4)"
    SSH_FLAG="$(echo "$result" | cut -d'|' -f5)"
    DEBUG_FLAG="${DEBUG_FLAG:-$(echo "$result" | cut -d'|' -f6)}"
    DOCKER_FLAG="$(echo "$result" | cut -d'|' -f7)"
    OPENROUTER_FLAG="$(echo "$result" | cut -d'|' -f9)"

    # Handle help flag
    if [ "$help_req" -eq 1 ]; then
        usage
        exit 0
    fi

    # Handle invalid option
    if [ "$invalid_opt" -eq 1 ]; then
        log_error "Unknown option: $(echo "$*" | grep -oE '(-[^ ]|--[^ ])' | head -1)"
        log_error "Run '$(basename "$0") create --help' for usage."
        exit 1
    fi

    # Missing option value (e.g. '--mount' as the last argument) —
    # extract_name_and_options already reported which option.
    if [ "$(echo "$result" | cut -d'|' -f8)" -eq 1 ]; then
        log_error "Run '$(basename "$0") create --help' for usage."
        exit 1
    fi

    # Generate name if not provided, otherwise ensure prefix
    if [ -z "$name" ]; then
        name="$(generate_random_name)"
    else
        name="$(ensure_prefix "$name")"
    fi

    # Refuse to overwrite an existing container (running or stopped)
    if container_exists "$name"; then
        log_error "Container '${name}' already exists."
        if container_is_running "$name"; then
            log_error "Stop it with 'pia stop ${name}' or use 'pia restart ${name}'."
        else
            log_error "Start it with 'pia run ${name}' or use 'pia ask ${name} <PROMPT>'."
        fi
        exit 1
    fi

    # Validate image exists
    if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
        log_error "Image '${IMAGE_NAME}' not found."
        log_error "Build it first: cd ../docker && ./build-docker.sh"
        exit 1
    fi

    # Create (without starting)
    resolve_openrouter_key
    log_info "Creating agent container '${name}' from image '${IMAGE_NAME}' (not started)..."
    local docker_args=()
    while IFS= read -r arg; do
        docker_args+=("$arg")
    done < <(build_docker_args "$name")

    local docker_cmd="docker create ${docker_args[*]}"
    log_cmd "$docker_cmd"
    if ! docker create "${docker_args[@]}" > /dev/null; then
        log_error "Failed to create container '${name}'."
        log_error "Make sure the image '${IMAGE_NAME}' exists. Run './scripts/build-docker.sh' first."
        exit 1
    fi

    log_info "Container '${name}' created but not started."
    log_info "Start it later with 'pia run ${name}', or run a prompt with 'pia ask ${name} <PROMPT>'."
}

cmd_run() {
    local name help_req invalid_opt
    local result
    result="$(extract_name_and_options "$@")"
    name="$(echo "$result" | cut -d'|' -f1)"
    help_req="$(echo "$result" | cut -d'|' -f2)"
    invalid_opt="$(echo "$result" | cut -d'|' -f3)"
    MOUNT_DIR="$(echo "$result" | cut -d'|' -f4)"
    SSH_FLAG="$(echo "$result" | cut -d'|' -f5)"
    DEBUG_FLAG="${DEBUG_FLAG:-$(echo "$result" | cut -d'|' -f6)}"
    DOCKER_FLAG="$(echo "$result" | cut -d'|' -f7)"
    OPENROUTER_FLAG="$(echo "$result" | cut -d'|' -f9)"

    # Handle help flag
    if [ "$help_req" -eq 1 ]; then
        usage
        exit 0
    fi

    # Handle invalid option
    if [ "$invalid_opt" -eq 1 ]; then
        log_error "Unknown option: $(echo "$*" | grep -oE '(-[^ ]|--[^ ])' | head -1)"
        log_error "Run '$(basename "$0") run --help' for usage."
        exit 1
    fi

    # Missing option value (e.g. '--mount' as the last argument) —
    # extract_name_and_options already reported which option.
    if [ "$(echo "$result" | cut -d'|' -f8)" -eq 1 ]; then
        log_error "Run '$(basename "$0") run --help' for usage."
        exit 1
    fi

    # Generate name if not provided, otherwise ensure prefix
    if [ -z "$name" ]; then
        name="$(generate_random_name)"
    else
        name="$(ensure_prefix "$name")"
    fi

    # Check if container already exists
    if container_exists "$name"; then
        if container_is_running "$name"; then
            log_error "Container '${name}' is already running."
            log_error "Use 'pia exec ${name}' to interact, or 'pia restart ${name}' to restart."
            exit 1
        else
            log_info "Container '${name}' exists but is stopped. Starting it..."
            attach_session "$name"
            exit $?
        fi
    fi

    # Validate image exists
    if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
        log_error "Image '${IMAGE_NAME}' not found."
        log_error "Build it first: cd ../docker && ./build-docker.sh"
        exit 1
    fi

    # Build and run
    resolve_openrouter_key
    log_info "Starting agent container '${name}' from image '${IMAGE_NAME}'..."
    local docker_args=()
    while IFS= read -r arg; do
        docker_args+=("$arg")
    done < <(build_docker_args "$name")

    local docker_cmd="docker run -d ${docker_args[*]}"
    log_cmd "$docker_cmd"
    if ! docker run -d "${docker_args[@]}" > /dev/null; then
        log_error "Failed to create container '${name}'."
        log_error "Make sure the image '${IMAGE_NAME}' exists. Run './scripts/build-docker.sh' first."
        exit 1
    fi

    # Attach an interactive pi session; the container stops with the session.
    local exit_code=0
    start_session "$name" || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_info "Container '${name}' started successfully."
    else
        log_error "Container '${name}' exited with code ${exit_code}."
    fi

    exit $exit_code
}

cmd_stop() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") stop [NAME]"
                echo ""
                echo "Stops a named agent container."
                echo ""
                echo "If NAME is omitted, shows available containers."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift ;;
        esac
    done

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        log_error "Please provide a container name."
        log_error "Run '$(basename "$0") stop --help' for usage."
        exit 1
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if container_is_running "$name"; then
        log_info "Stopping container '${name}'..."
        log_cmd "docker stop ${name}"
        docker stop "$name" > /dev/null 2>&1 || true
    else
        log_info "Container '${name}' is already stopped."
    fi

    log_info "Container '${name}' stopped."
}

cmd_rm() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") remove [NAME]"
                echo ""
                echo "Removes a named agent container."
                echo ""
                echo "If NAME is omitted, shows available containers."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift ;;
        esac
    done

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        log_error "Please provide a container name."
        log_error "Run '$(basename "$0") remove --help' for usage."
        exit 1
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if container_is_running "$name"; then
        log_info "Stopping container '${name}' before removing..."
        log_cmd "docker stop ${name}"
        docker stop "$name" > /dev/null 2>&1 || true
    fi

    log_info "Removing container '${name}'..."
    log_cmd "docker rm ${name}"
    docker rm "$name" > /dev/null 2>&1 || true
    log_info "Container '${name}' removed."
}

# 'list' selects no container and takes no arguments — an argument would be
# silently ignored, so reject it instead.
cmd_ls() {
    local extra=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") list"
                echo ""
                echo "Lists every agent container (running and stopped)."
                echo ""
                echo "Takes no arguments. For a single container use:"
                echo "  docker ps -a --filter name=^pia-<NAME>"
                exit 0 ;;
            *)
                if [ -z "$extra" ]; then
                    extra="$1"
                fi
                shift ;;
        esac
    done

    if [ -n "$extra" ]; then
        log_error "'list' does not take arguments (got '${extra}')."
        log_error "It always lists every agent container; for one container use 'docker ps -a --filter name=^pia-${extra}'."
        exit 1
    fi

    echo ""
    echo "Pi Agent Containers:"
    echo "────────────────────────────────────────────────────────────────"
    printf "%-30s %-10s %s\n" "NAME" "STATUS" "CREATED"
    echo "────────────────────────────────────────────────────────────────"

    local found=0

    # pia_ps already selects the project; no extra name filtering here
    # (tab separators keep Status and CreatedAt fields with spaces intact)
    while IFS=$'\t' read -r id name state created; do
        if [ -z "$id" ]; then continue; fi

        found=1
        printf "%-30s %-10s %s\n" "$name" "$state" "$created"
    done < <(pia_ps)

    if [ $found -eq 0 ]; then
        echo "(no agent containers found)"
    fi

    echo "────────────────────────────────────────────────────────────────"
    echo ""
}

cmd_restart() {
    local name help_req invalid_opt
    local result
    result="$(extract_name_and_options "$@")"
    name="$(echo "$result" | cut -d'|' -f1)"
    help_req="$(echo "$result" | cut -d'|' -f2)"
    invalid_opt="$(echo "$result" | cut -d'|' -f3)"
    MOUNT_DIR="$(echo "$result" | cut -d'|' -f4)"
    SSH_FLAG="$(echo "$result" | cut -d'|' -f5)"
    DEBUG_FLAG="${DEBUG_FLAG:-$(echo "$result" | cut -d'|' -f6)}"
    DOCKER_FLAG="$(echo "$result" | cut -d'|' -f7)"
    OPENROUTER_FLAG="$(echo "$result" | cut -d'|' -f9)"

    # Handle help flag
    if [ "$help_req" -eq 1 ]; then
        usage
        exit 0
    fi

    # Handle invalid option
    if [ "$invalid_opt" -eq 1 ]; then
        log_error "Unknown option: $(echo "$*" | grep -oE '(-[^ ]|--[^ ])' | head -1)"
        log_error "Run '$(basename "$0") restart --help' for usage."
        exit 1
    fi

    # Missing option value (e.g. '--mount' as the last argument) —
    # extract_name_and_options already reported which option.
    if [ "$(echo "$result" | cut -d'|' -f8)" -eq 1 ]; then
        log_error "Run '$(basename "$0") restart --help' for usage."
        exit 1
    fi

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        log_error "Please provide a container name to restart."
        log_error "Run '$(basename "$0") restart --help' for usage."
        exit 1
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    # Validate image exists
    if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
        log_error "Image '${IMAGE_NAME}' not found."
        log_error "Build it first: cd ../docker && ./build-docker.sh"
        exit 1
    fi

    # Stop the existing container
    log_info "Stopping container '${name}'..."
    log_cmd "docker stop ${name}"
    docker stop "$name" > /dev/null 2>&1 || true

    # Remove the container
    log_info "Removing container '${name}'..."
    log_cmd "docker rm ${name}"
    docker rm "$name" > /dev/null 2>&1 || true

    # Start a fresh container with the same name
    resolve_openrouter_key
    log_info "Starting fresh agent container '${name}' from image '${IMAGE_NAME}'..."
    local docker_args=()
    while IFS= read -r arg; do
        docker_args+=("$arg")
    done < <(build_docker_args "$name")

    local docker_cmd="docker run -d ${docker_args[*]}"
    log_cmd "$docker_cmd"
    if ! docker run -d "${docker_args[@]}" > /dev/null; then
        log_error "Failed to create container '${name}'."
        log_error "Make sure the image '${IMAGE_NAME}' exists. Run './scripts/build-docker.sh' first."
        exit 1
    fi

    # Attach an interactive pi session; the container stops with the session.
    local exit_code=0
    start_session "$name" || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_info "Container '${name}' restarted successfully."
    else
        log_error "Container '${name}' exited with code ${exit_code}."
    fi

    exit $exit_code
}

cmd_exec() {
    local name=""
    local cmd=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") exec [NAME] [CMD]"
                echo ""
                echo "Execute a command in a running agent container."
                echo ""
                echo "If CMD is omitted, opens an interactive shell."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                else
                    # Append all remaining args as the command
                    cmd="${cmd:+$cmd }$1"
                fi
                shift ;;
        esac
    done

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        log_error "Please provide a container name."
        log_error "Run '$(basename "$0") exec --help' for usage."
        exit 1
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if ! container_is_running "$name"; then
        log_error "Container '${name}' is not running. Start it with 'pia run ${name}'."
        exit 1
    fi

    if [ -n "$cmd" ]; then
        log_cmd "docker exec ${name} bash -c \"${cmd}\""
        docker exec "$name" bash -c "$cmd"
    else
        log_cmd "docker exec -it ${name} /bin/bash"
        docker exec -it "$name" /bin/bash
    fi
}

# Stop the in-container sampler started by 'pia monitor'. 'docker exec' without
# a TTY signals only the helper, never the capture it started, so an
# interrupted monitor has to stop the helper itself — otherwise 'pia-monitor'
# and its tshark go on running inside the container after the terminal is gone.
# The pattern matches ONLY the monitor's own helpers, not the capture: the
# helper's own signal handler stops the tshark it owns (see
# docker/monitor-inside.sh), and naming tshark here would also kill a tshark
# the agent is running for its own work — or the long-running 'pia-monitor log'
# destination logger that backs 'pia urls', which must survive every monitor.
# Stopping a second monitor watching the same container is intended (one
# terminal, one monitor). See the body for why stopping is confirmed, not assumed.
monitor_stop_sampler() {
    local name="$1" rc i
    # 'pkill' exits as soon as the signal is delivered, and the helper's handler
    # still has to stop its capture and exit, so 'killed' is not yet 'gone'.
    # Confirm instead of assuming — the promise of 'pia monitor' is that nothing
    # keeps capturing once it returns, and a caller checking right afterwards
    # would otherwise see the helper die for a few milliseconds. pkill's exit 1
    # means 'no process matched', which IS the clean state; the helper dies
    # quickly, so this settles on the second probe in practice.
    for i in 1 2 3; do
        rc=0
        docker exec "$name" pkill -f 'pia-monitor (cycle|raw)' > /dev/null 2>&1 || rc=$?
        [ "$rc" -ne 0 ] && return 0
        sleep 0.2
    done
    # Still alive after three probes: a hand-started helper that ignores signals.
    # Say so rather than let the silence imply the container is clean.
    log_warn "A 'pia-monitor' helper is still running in '${name}' — stop it with: docker exec ${name} pkill -f 'pia-monitor (cycle|raw)'"
    return 0
}

# Name of the only running agent container, or empty if there is not exactly
# one. Lets 'pia sh' work without a name in the common single-container case.
sole_running_container() {
    local names count
    names="$(pia_ps --filter status=running | cut -f2 | sed 's|^/||')"
    count="$(printf '%s\n' "$names" | grep -c . || true)"
    if [ "${count:-0}" -eq 1 ]; then
        printf '%s\n' "$names"
    fi
}

# Open an interactive bash shell inside a running agent container, so commands
# can be run by hand (ls, git, curl to the proxies, etc.).
cmd_sh() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") sh [NAME]"
                echo ""
                echo "Open an interactive bash shell in a running agent container."
                echo ""
                echo "If NAME is omitted and exactly one agent container is running,"
                echo "that container is used. To run a single command instead, use"
                echo "'$(basename "$0") exec [NAME] [CMD]'."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                    shift
                else
                    log_error "Unexpected argument: $1"
                    log_error "Run '$(basename "$0") sh --help' for usage."
                    exit 1
                fi ;;
        esac
    done

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        name="$(sole_running_container)"
        if [ -n "$name" ]; then
            log_info "Using the only running container: ${name}"
        else
            log_error "Please provide a container name."
            log_error "Run '$(basename "$0") list' to see containers, or 'sh --help' for usage."
            exit 1
        fi
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if ! container_is_running "$name"; then
        log_error "Container '${name}' is not running. Start it with 'pia run ${name}'."
        exit 1
    fi

    local exec_args
    exec_args="$(exec_tty_args)"
    log_cmd "docker exec ${exec_args} ${name} /bin/bash"
    # shellcheck disable=SC2086  # exec_args is intentionally word-split
    exec docker exec ${exec_args} "$name" /bin/bash
}

# Live view of a running agent container: where its network requests go (TLS
# SNI hostnames, plus full URLs for cleartext HTTP) alongside CPU, memory, pids
# and net I/O. The sampling itself runs inside the container by the
# 'pia-monitor' helper (docker/monitor-inside.sh); this command only resolves the
# container and loops. The monitor writes nothing to disk anywhere — docker exec
# streams the lines straight to this terminal. (The container may still keep a
# destination log for 'pia urls'; this command neither reads nor writes it.)
cmd_monitor() {
    local name="" interval="" mode="cycle"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") monitor [NAME] [OPTIONS]"
                echo ""
                echo "Watch a running agent container: request destinations (TLS SNI hostnames"
                echo "and full cleartext HTTP URLs) plus CPU, memory, pids and net I/O."
                echo ""
                echo "Output goes to the terminal only — no log files are written by the monitor."
                echo "For the full request history since container creation, use 'urls'."
                echo "Press Ctrl-C to stop."
                echo ""
                echo "Options:"
                echo "  -i, --interval <sec>  Seconds per sample cycle (default: 3); with --raw"
                echo "                        it is the length of one capture chunk (default: 5)"
                echo "      --raw             Stream destinations continuously, no resource summary"
                echo ""
                echo "Notes:"
                echo "  * HTTPS hides the URL path — only the hostname (SNI) is visible. Full"
                echo "    URLs are shown for cleartext HTTP (the local proxy servers, etc.)."
                echo "  * NAME may be omitted when exactly one container is running."
                echo "  * Ctrl-C, or the container stopping, also stops the capture inside"
                echo "    the container — nothing is left running behind us."
                exit 0 ;;
            -i|--interval)
                shift
                if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
                    log_error "Option '--interval' requires a value (seconds)."
                    log_error "Run '$(basename "$0") monitor --help' for usage."
                    exit 1
                fi
                interval="$1" ;;
            --raw)
                mode="raw" ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                else
                    log_error "Unexpected argument: $1"
                    log_error "Run '$(basename "$0") monitor --help' for usage."
                    exit 1
                fi ;;
        esac
        shift
    done

    # Unset means 'the default for this mode': a raw capture wants a longer
    # chunk than a sample cycle, because every chunk restarts the capture and a
    # restart costs a blind window (see the loop below) — but an explicit -i is
    # honoured in both modes, it would be a silent surprise otherwise.
    if [ -z "$interval" ]; then
        if [ "$mode" = "raw" ]; then
            interval="$MONITOR_RAW_CHUNK"
        else
            interval="$MONITOR_CYCLE_SECONDS"
        fi
    fi

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
        log_error "Interval must be a whole number of seconds (got '${interval}')."
        exit 1
    fi

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        name="$(sole_running_container)"
        if [ -n "$name" ]; then
            log_info "Using the only running container: ${name}"
        else
            log_error "Please provide a container name."
            log_error "Run '$(basename "$0") list' to see containers, or 'monitor --help' for usage."
            exit 1
        fi
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if ! container_is_running "$name"; then
        log_error "Container '${name}' is not running. Start it with 'pia run ${name}'."
        exit 1
    fi

    # Images built before the monitor existed have no helper inside. The check
    # goes through 'sh -c' because 'command' is a shell builtin — docker exec
    # would otherwise look for an executable file literally named 'command'.
    log_cmd "docker exec ${name} sh -c 'command -v pia-monitor'"
    if ! docker exec "$name" sh -c 'command -v pia-monitor > /dev/null 2>&1'; then
        log_error "The image used by '${name}' has no 'pia-monitor' helper."
        log_error "Rebuild it (bash scripts/build-docker.sh), then recreate the container"
        log_error "with 'pia restart ${name}'."
        exit 1
    fi

    # Both exits must leave the container clean: Ctrl-C (or a closed terminal)
    # cannot reach the capture through 'docker exec', so stopping the sampler is
    # done from here. The EXIT trap covers the paths that do not go through the
    # INT/TERM one — a broken capture, or the container disappearing. The name is
    # interpolated because it is a function-local, already gone by the time the
    # script exits.
    trap 'printf "\n"; log_info "Monitor stopped."; exit 0' INT TERM
    trap "monitor_stop_sampler '$name'" EXIT

    # Each pass is one 'docker exec' of the in-container helper, so a container
    # that disappears mid-monitoring ends the loop instead of erroring forever.
    # Raw mode is chunked for the same reason: one unbounded exec would hang on a
    # vanished container, and a Ctrl-C that only reaches this shell would leave a
    # capture running for as long as tshark liked. The chunk bounds both.
    #
    # The price is a blind window at every chunk boundary — 'docker exec' setup,
    # the helper's startup, and tshark's own start add up to roughly 0.5s
    # measured (100 handshakes at ~5/s: 88 seen with 5s chunks, 97 with 10s,
    # which is what one gapless capture sees). What the chunk bounds on the stop
    # side is the quiet case — a signal that reaches only this shell, where the
    # handler waits for the in-flight exec (real Ctrl-C signals the whole
    # foreground group and is answered in ~0.3s at any chunk length). 5s is the
    # middle of that line and -i moves it either way.
    local sampler_mode="$mode" sampler_seconds="$interval"
    if [ "$mode" = "raw" ]; then
        log_info "Streaming destinations from '${name}' — Ctrl-C to stop."
    else
        log_info "Monitoring '${name}' — destinations every cycle, resources every ${interval}s. Ctrl-C to stop."
    fi
    log_info "Legend: 'TLS host (ip)' = HTTPS peer, path stays encrypted · 'HTTP <method> <url>' = cleartext request"

    local rc=0
    while container_is_running "$name"; do
        rc=0
        docker exec "$name" pia-monitor "$sampler_mode" "$sampler_seconds" || rc=$?
        # A sampler that stopped together with the container is not a broken
        # capture — the loop condition turns that into the plain 'it is gone'
        # ending. Any other non-zero exit already explained itself inside the
        # container (missing CAP_NET_RAW, vanished interface, ...).
        if [ "$rc" -ne 0 ] && container_is_running "$name"; then
            log_warn "Monitor stopped — the sampler exited with code ${rc}."
            exit 1
        fi
    done

    log_warn "Container '${name}' is no longer running — monitor ended."
}

# Every destination (TLS SNI hostnames) and cleartext HTTP URL the container
# has called since it was created. The container's entrypoint starts
# 'pia-monitor log' (docker/monitor-inside.sh) on every container start, which
# appends each request to a log on the container's own filesystem — so the
# history survives 'pia stop'/'pia run' cycles and is lost only with
# 'pia remove'. This command only resolves the container and asks the helper
# to print the log (aggregated by destination, or raw with '--all').
cmd_urls() {
    local name="" all=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") urls [NAME] [OPTIONS]"
                echo ""
                echo "List every destination (TLS SNI hostnames) and cleartext HTTP URL the"
                echo "container has called since it was created, with first-seen time and"
                echo "hit count per destination."
                echo ""
                echo "The container's entrypoint keeps a small tshark logger running from"
                echo "the moment it is created, so the history covers the container's whole"
                echo "life — it survives 'pia stop' and 'pia run', and is lost only when the"
                echo "container is removed. HTTPS hides the URL path: for https:// requests"
                echo "only the hostname (SNI) is visible in the clear."
                echo ""
                echo "Options:"
                echo "  -a, --all   Every logged request in order, no aggregation"
                echo ""
                echo "Notes:"
                echo "  * NAME may be omitted when exactly one container is running."
                echo "  * The log lives inside the container; the container must be running"
                echo "    (start it with 'pia run NAME' — the history is still there)."
                exit 0 ;;
            -a|--all)
                all="yes" ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                else
                    log_error "Unexpected argument: $1"
                    log_error "Run '$(basename "$0") urls --help' for usage."
                    exit 1
                fi ;;
        esac
        shift
    done

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        name="$(sole_running_container)"
        if [ -n "$name" ]; then
            log_info "Using the only running container: ${name}"
        else
            log_error "Please provide a container name."
            log_error "Run '$(basename "$0") list' to see containers, or 'urls --help' for usage."
            exit 1
        fi
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if ! container_is_running "$name"; then
        log_error "Container '${name}' is not running. Start it with 'pia run ${name}'."
        exit 1
    fi

    # Images built before the monitor existed have no helper inside; images
    # built before the URL logger exist do have it, and the helper itself
    # explains that the log is missing and how to recover.
    log_cmd "docker exec ${name} sh -c 'command -v pia-monitor'"
    if ! docker exec "$name" sh -c 'command -v pia-monitor > /dev/null 2>&1'; then
        log_error "The image used by '${name}' has no 'pia-monitor' helper."
        log_error "Rebuild it (bash scripts/build-docker.sh), then recreate the container"
        log_error "with 'pia restart ${name}'."
        exit 1
    fi

    if [ -n "$all" ]; then
        log_cmd "docker exec ${name} pia-monitor urls all"
        exec docker exec "$name" pia-monitor urls all
    fi
    log_cmd "docker exec ${name} pia-monitor urls"
    exec docker exec "$name" pia-monitor urls
}

# One-shot non-interactive prompt through pi's print mode (--print).
# With NAME: runs inside that container (started if stopped, stopped again
# afterwards if we started it). Without NAME: an ephemeral container is
# created from the image and removed when the prompt is done.
cmd_ask() {
    local name=""
    local prompt_parts=()

    # build_docker_args reads these globals; 'ask' takes no mount/ssh/docker/openrouter flags
    MOUNT_DIR=""
    SSH_FLAG=""
    DOCKER_FLAG=""
    OPENROUTER_FLAG=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") ask [NAME] [PROMPT...]"
                echo ""
                echo "Run a one-shot non-interactive pi prompt (pi --print)."
                echo ""
                echo "The first argument is the container NAME only if such a"
                echo "container exists; otherwise all arguments form the prompt."
                echo "With NAME the prompt runs inside that container; if it is"
                echo "stopped it is started and stopped again afterwards."
                echo "Without NAME an ephemeral container is created and removed."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                else
                    prompt_parts+=("$1")
                fi
                shift ;;
        esac
    done

    # The first argument is a NAME only if the container actually exists;
    # otherwise everything (including it) is the prompt of an ephemeral ask.
    if [ ${#prompt_parts[@]} -eq 0 ] && [ -n "$name" ] && ! container_exists "$(ensure_prefix "$name")"; then
        prompt_parts=("$name")
        name=""
    fi

    if [ ${#prompt_parts[@]} -eq 0 ]; then
        log_error "Please provide a prompt."
        log_error "Run '$(basename "$0") ask --help' for usage."
        exit 1
    fi
    local prompt="${prompt_parts[*]}"

    local ephemeral=""
    if [ -z "$name" ]; then
        name="$(generate_random_name)"
        ephemeral="yes"
    else
        name="$(ensure_prefix "$name")"
    fi

    if [ -z "$ephemeral" ] && ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        log_error "Use 'pia run ${name}' first, or omit NAME for a one-shot container."
        exit 1
    fi

    # Validate image exists when a container must be created
    if [ -n "$ephemeral" ] && ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
        log_error "Image '${IMAGE_NAME}' not found."
        log_error "Build it first: cd ../docker && ./build-docker.sh"
        exit 1
    fi

    local started_by_us=""
    if [ -n "$ephemeral" ]; then
        # No resolve_openrouter_key here: OPENROUTER_FLAG is forced empty
        # above, so 'ask' never forwards a key (see README).
        log_info "Creating one-shot container '${name}'..."
        local docker_args=()
        while IFS= read -r arg; do
            docker_args+=("$arg")
        done < <(build_docker_args "$name")
        log_cmd "docker run -d ${docker_args[*]}"
        if ! docker run -d "${docker_args[@]}" > /dev/null; then
            log_error "Failed to create container '${name}'."
            exit 1
        fi
        wait_running "$name" || log_warn "Container '${name}' did not report running — trying anyway."
    elif ! container_is_running "$name"; then
        log_info "Starting stopped container '${name}'..."
        log_cmd "docker start ${name}"
        if ! docker start "$name" > /dev/null 2>&1; then
            log_error "Failed to start container '${name}'."
            exit 1
        fi
        started_by_us="yes"
    fi

    # Pin to the container ID so a rename during the run cannot orphan the
    # cleanup below ('pia rename'/'pia keep' may run from another terminal).
    # The container is guaranteed to exist here (just created, or checked and
    # started above), so an empty ID means it vanished — abort instead of
    # degrading to name-based cleanup, which is what this pinning prevents.
    local id
    id="$(container_id "$name")"
    if [ -z "$id" ]; then
        log_error "Container '${name}' disappeared before the session could run."
        exit 1
    fi

    log_cmd "docker exec ${name} pi --print <prompt>"
    local rc=0
    docker exec "$id" pi --print "$prompt" || rc=$?

    if [ -n "$ephemeral" ]; then
        log_cmd "docker rm -f ${name}"
        docker rm -f "$id" > /dev/null 2>&1
    elif [ -n "$started_by_us" ] && container_is_running "$id"; then
        log_cmd "docker stop ${name}"
        docker stop "$id" > /dev/null 2>&1
    fi

    exit $rc
}

# 'clean' acts on every stopped container and takes no arguments — an argument
# (including --help) must not be ignored, or a typo would delete containers.
cmd_clean() {
    local extra=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") clean"
                echo ""
                echo "Removes every stopped agent container."
                echo ""
                echo "Takes no arguments. Kept containers (pia-keep-*) are never removed;"
                echo "to remove a single container use: $(basename "$0") rm <NAME>"
                exit 0 ;;
            *)
                if [ -z "$extra" ]; then
                    extra="$1"
                fi
                shift ;;
        esac
    done

    if [ -n "$extra" ]; then
        log_error "'clean' does not take arguments (got '${extra}')."
        log_error "It always removes every stopped agent container; for one container use 'pia rm <NAME>'."
        exit 1
    fi

    log_info "Removing all stopped agent containers..."
    local count=0

    # List all stopped containers matching our prefix and remove them.
    # Kept containers (pia-keep-*) are protected and never removed.
    while IFS= read -r name; do
        if [ -z "$name" ]; then continue; fi
        if [[ "$name" == ${KEEP_PREFIX}* ]]; then
            log_info "Skipping protected container '${name}'."
            continue
        fi
        log_info "Removing stopped container '${name}'..."
        log_cmd "docker rm ${name}"
        docker rm "$name" > /dev/null 2>&1 || true
        count=$((count + 1))
    done < <(pia_ps --filter "status=exited" | cut -f2)

    if [ $count -eq 0 ]; then
        log_info "No stopped agent containers to remove."
    else
        log_info "Removed ${count} stopped container(s)."
    fi
}

cmd_keep() {
    local name=""
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") keep [NAME] [SUFFIX]"
                echo ""
                echo "Protects a container from 'pia clean' by renaming it to pia-keep-*."
                echo ""
                echo "Without SUFFIX, 'pia-zzz' is renamed to 'pia-keep-zzz'."
                echo "With SUFFIX, the container is renamed to 'pia-keep-<SUFFIX>'."
                echo "Works on running and stopped containers."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                elif [ -z "$target" ]; then
                    target="$1"
                fi
                shift ;;
        esac
    done

    if [ -z "$name" ]; then
        log_error "Please provide a container name."
        log_error "Run '$(basename "$0") keep --help' for usage."
        exit 1
    fi

    # Ensure prefix on custom name
    name="$(ensure_prefix "$name")"

    # Accept the kept name directly (e.g. 'pia-keep-zzz') as the argument too
    if ! container_exists "$name" && [[ "$name" != ${KEEP_PREFIX}* ]]; then
        if container_exists "$(add_keep "$name")"; then
            name="$(add_keep "$name")"
        fi
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    local new_name
    if [ -n "$target" ]; then
        new_name="$(to_keep_name "$target")"
    elif [[ "$name" == ${KEEP_PREFIX}* ]]; then
        log_info "Container '${name}' is already kept."
        exit 0
    else
        new_name="$(add_keep "$name")"
    fi

    do_rename "$name" "$new_name"
}

cmd_unkeep() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") unkeep [NAME]"
                echo ""
                echo "Removes the keep protection from a container,"
                echo "renaming it from pia-keep-* back to pia-*."
                echo ""
                echo "Accepts 'zzz', 'pia-zzz', or 'pia-keep-zzz' — all resolve to the kept container."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift ;;
        esac
    done

    if [ -z "$name" ]; then
        log_error "Please provide a container name."
        log_error "Run '$(basename "$0") unkeep --help' for usage."
        exit 1
    fi

    # Normalize: accept 'zzz', 'pia-zzz', or 'pia-keep-zzz'.
    if [[ "$name" != ${KEEP_PREFIX}* ]]; then
        name="$(ensure_prefix "$name")"
        if ! container_exists "$name" && container_exists "$(add_keep "$name")"; then
            name="$(add_keep "$name")"
        fi
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if [[ "$name" != ${KEEP_PREFIX}* ]]; then
        log_error "Container '${name}' is not kept. Nothing to unkeep."
        exit 1
    fi

    do_rename "$name" "$(strip_keep "$name")"
}

cmd_rename() {
    local name=""
    local new_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") rename [NAME] [NEW]"
                echo ""
                echo "Renames a container."
                echo ""
                echo "Both names get the 'pia-' prefix automatically unless they"
                echo "already start with 'pia-' or 'pia-keep-'."
                echo "Works on running and stopped containers."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                elif [ -z "$new_name" ]; then
                    new_name="$1"
                fi
                shift ;;
        esac
    done

    if [ -z "$name" ] || [ -z "$new_name" ]; then
        log_error "Please provide the current name and the new name."
        log_error "Run '$(basename "$0") rename --help' for usage."
        exit 1
    fi

    # Ensure prefix, but allow renaming into the keep namespace (pia-keep-*)
    name="$(ensure_prefix "$name")"
    if [[ "$new_name" != ${KEEP_PREFIX}* ]]; then
        new_name="$(ensure_prefix "$new_name")"
    fi

    do_rename "$name" "$new_name"
}


cmd_resume() {
    local requested=""

    # 'resume' selects the container itself; a name here would be silently
    # ignored and the wrong session started, so reject it instead.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") resume"
                echo ""
                echo "Starts the most recently stopped agent container and continues its last pi session."
                echo ""
                echo "This command takes no container name. To continue a specific"
                echo "container, use: $(basename "$0") run <NAME>"
                exit 0 ;;
            *)
                if [ -z "$requested" ]; then
                    requested="$1"
                fi
                shift ;;
        esac
    done

    if [ -n "$requested" ]; then
        log_error "'resume' does not take a container name (got '${requested}')."
        log_error "It always continues the most recently stopped container; to continue a specific one use 'pia run ${requested}'."
        exit 1
    fi

    log_info "Resuming the latest stopped agent container..."

    # Find the container that stopped most recently (not the newest-created
    # one — see pia_last_stopped).
    local name
    name=$(pia_last_stopped)

    if [ -z "$name" ]; then
        log_info "No stopped agent containers found to resume."
        exit 0
    fi

    if ! container_exists "$name"; then
        log_error "Container '${name}' does not exist."
        exit 1
    fi

    if container_is_running "$name"; then
        log_info "Container '${name}' is already running."
        exit 0
    fi

    log_info "Starting stopped container '${name}'..."
    attach_session "$name"
    exit $?
}


###################################################################################################
# MAIN
###################################################################################################

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

# Global flags (can appear before or after the subcommand)
# First pass: scan for --debug anywhere in args
for arg in "$@"; do
    case "$arg" in
        -d|--debug)
            DEBUG_FLAG="yes"
            ;;
    esac
done

# Second pass: rebuild args without global flags
CLEAN_ARGS=()
for arg in "$@"; do
    case "$arg" in
        -d|--debug) ;;  # skip
        *) CLEAN_ARGS+=("$arg") ;;
    esac
done

COMMAND="${CLEAN_ARGS[0]}"
shift "${#CLEAN_ARGS[@]}"
set -- "${CLEAN_ARGS[@]:1}"

case "$COMMAND" in
    run)
        cmd_run "$@" ;;
    create)
        cmd_create "$@" ;;
    stop)
        cmd_stop "$@" ;;
    remove)
        cmd_rm "$@" ;;
    rm)
        cmd_rm "$@" ;;
    list)
        cmd_ls "$@" ;;
    ls)
        cmd_ls "$@" ;;
    clean)
        cmd_clean "$@" ;;
    resume)
        cmd_resume "$@" ;;
    rs)
        cmd_resume "$@" ;;
    restart)
        cmd_restart "$@" ;;
    ask)
        cmd_ask "$@" ;;
    exec)
        cmd_exec "$@" ;;
    sh)
        cmd_sh "$@" ;;
    shell)
        cmd_sh "$@" ;;
    monitor)
        cmd_monitor "$@" ;;
    urls)
        cmd_urls "$@" ;;
    keep)
        cmd_keep "$@" ;;
    unkeep)
        cmd_unkeep "$@" ;;
    rename)
        cmd_rename "$@" ;;
    -h|--help|help)
        usage ;;
    *)
        log_error "Unknown command: ${COMMAND}"
        log_error "Run '$(basename "$0") --help' for usage."
        exit 1 ;;
esac
