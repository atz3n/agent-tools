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
#   pia restart [NAME] [OPTIONS] Restart a named container, continuing its last pi session
#                      (re-creates the container only when run flags change;
#                      --fresh forces a recreate with a fresh pi session)
#   pia ask   [NAME] [PROMPT]   Run a one-shot non-interactive pi prompt (pi --print)
#   pia exec    [NAME] [CMD]    Execute a command in a running container
#   pia sh      [NAME]          Open an interactive bash shell in a running container
#   pia monitor [NAME]          Live view: request destinations + CPU/mem/net
#                               (a chart dashboard on a terminal, a line per sample when piped)
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
#       --docker       Give the container a throwaway sibling Docker daemon
#                      (a 'NAME-dind' container with NO host mounts; the host
#                      socket is never visible inside the agent)
#       --docker-dev   Also mount the '-m' workspace into that daemon, so
#                      nested bind mounts resolve (needs -m)
#       --docker-full  Mount the HOST socket — host-root-equivalent, loud
#                      banner, refused by 'pia ask'
#   -h, --help         Display this help message
#
# Command options (restart):
#       --fresh        Force a recreate and start a FRESH pi session
#                      (alias: --no-continue). Without it, restart continues
#                      the last pi session and only re-creates the container
#                      when the given flags actually differ from its config.
#
# Command options (monitor):
#   -i, --interval <sec>  Seconds per resource sample (default: 1)
#       --raw             Stream destinations continuously, no resource summary
#       --chart           Draw the dashboard even when stdout is not a terminal
#       --no-chart        The line view, even on a terminal
#
# Command options (urls):
#   -a, --all             Every logged request in order, no aggregation
#
# Examples:
#   pia run                  # Start with auto-generated name
#   pia run my-project       # Start with custom name
#   pia run -m /path/to/proj # Start with mount, auto name
#   pia run proj -m . --ssh  # Start with name, mount, and SSH
#   pia run proj --docker    # Start with a throwaway sibling Docker daemon
#   pia run proj -m . --docker-dev  # ... and the daemon sees the workspace
#   pia create proj -m /path # Create stopped container for a later 'pia ask'
#   pia --debug run proj     # Show debug output (global flag)
#   pia list                   # List all containers
#   pia stop my-project        # Stop named container
#   pia remove my-project      # Remove named container
#   pia restart my-project -m . # Restart with a new mount, keeping the pi session
#   pia restart my-project      # Run flags unchanged — plain resume (pi --continue)
#   pia restart my-project --fresh # Recreate and start a clean pi session
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
MONITOR_CYCLE_SECONDS="1"  # default sample length for 'pia monitor' (see cmd_monitor)
MONITOR_RAW_CHUNK="5"      # default capture chunk for 'pia monitor --raw'; '-i' overrides it
DIND_SUFFIX="-dind"               # suffix of an agent's throwaway daemon container
DIND_IMAGE_DEFAULT="pia-dind"     # built daemon image (tag = guard version); PIA_DIND_IMAGE overrides fully
DIND_WS_TARGET="/workspace"       # where 'dind-mount' exposes the workspace inside the daemon
# guard policy version lives in docker/pia-dind/guard.sh (line 2 marker);
# read it with dind_guard_version() — there is no second copy to drift.


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

# List everything pia owns — agent instances AND their throwaway 'dind'
# daemon siblings. Internal helper; callers that auto-select containers
# (resume, clean, sole-running detection) must use pia_ps instead, which
# hides the plumbing. Extra arguments are passed to 'docker ps' as
# additional filters.
pia_ps_all() {
    local fmt='{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.CreatedAt}}'
    {
        docker ps -a --filter "name=^${PREFIX}" --format "$fmt" "$@" 2>/dev/null
        docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format "$fmt" "$@" 2>/dev/null
    } | awk -F'\t' '!seen[$1]++'
}

# List pia AGENT containers as 'id<TAB>name<TAB>status<TAB>created' —
# throwaway daemon siblings (label pia-role=dind) are plumbing and hidden.
# Exclusion is done here rather than with a 'label!=' docker filter because
# older daemons reject that filter syntax. Matches both the name prefix and
# the project label, so containers created before the labels existed (or
# outside the CLI) are found too.
# Extra arguments are passed to 'docker ps' as additional filters.
# NOTE: 'docker ps' orders by creation time, NOT by stop time — never use
# 'head -1' here to find "the latest stopped" container, use pia_last_stopped.
pia_ps() {
    local dind_names
    dind_names="$(docker ps -a --filter "label=pia-role=dind" --format '{{.Names}}' 2>/dev/null)"
    pia_ps_all "$@" | awk -F'\t' -v dinds="$dind_names" '
        BEGIN { n = split(dinds, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1 }
        !skip[$2]
    '
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
  list  [OPTIONS]              List all agent containers (-a/--all also shows
                               the throwaway 'dind' daemon containers)
  ls                           Alias for list
  clean                      Remove all stopped agent containers (except kept pia-keep-*)
  resume                     Start the most recently stopped agent container and continue its last pi session
                             (takes no NAME — use 'run <NAME>' to continue a specific container)
  rs                         Alias for resume
  restart [NAME] [OPTIONS]   Restart a named container, continuing its last pi session.
                             Unchanged (or omitted) flags → plain resume in place; changed
                             flags → re-create WITH the session carried over; --fresh → recreate
                             with a clean session. Options you do not pass keep the
                             container's current values.
  ask     [NAME] [PROMPT]    One-shot non-interactive pi prompt (pi --print); omit NAME if ephemeral
  exec    [NAME] [CMD]       Execute a command in a running container
  sh      [NAME]             Open an interactive bash shell in a running container (alias: shell)
                             (NAME may be omitted when exactly one container is running)
  dindlog [NAME]             Nested-container guard log of the agent's throwaway Docker
                             daemon — the refusal reasons behind opaque 'runc did not
                             terminate successfully' errors from nested docker runs
  monitor [NAME] [OPTIONS]   Live view of a running container: where its requests go
                             (TLS SNI / cleartext HTTP URLs) + CPU, memory, net I/O.
                             Charts on a terminal, one line per sample when piped
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
      --docker       Give the container a throwaway sibling Docker daemon
                     (sibling container 'NAME-dind', NO host mounts, host
                     socket never visible; the agent talks to it over the
                     shared network namespace at tcp://127.0.0.1:2375)
      --docker-dev   Like --docker, but also mount the '-m' workspace into
                     the daemon at the same path, so nested bind mounts
                     (compose configs, live source) work. Requires -m. The
                     daemon — and every container it runs — can then read
                     and write that one directory as root; nothing else on
                     the host becomes visible.
      --docker-full  Mount the HOST Docker socket; this is
                     host-root-equivalent by design: a loud banner
                     is shown and 'pia ask' refuses the mode
  -h, --help         Display this help message

Command options (restart):
      --fresh        Force a recreate and start a FRESH pi session
                     (alias: --no-continue). Without it, 'restart' continues
                     the container's last pi session ('pi --continue') and
                     re-creates the container only when the given flags
                     actually differ from its current config.

Command options (monitor):
  -i, --interval <sec>  Seconds per resource sample (default: 1)
      --raw             Stream destinations continuously, no resource summary
      --chart           Draw the chart dashboard even when stdout is not a terminal
      --no-chart        One line per sample, even on a terminal

Command options (urls):
  -a, --all             Every logged request in order, no aggregation
  -h, --help            Display help message

Command options (ls):
  -a, --all             Also list the throwaway 'dind' daemon containers
                        (plumbing, hidden by default)

Examples:
  $(basename "$0") run                  # Start with auto-generated name
  $(basename "$0") run my-project       # Start with custom name
  $(basename "$0") run -m /path/to/proj # Start with mount, auto name
  $(basename "$0") run proj -m . --ssh  # Start with name, mount, and SSH
  $(basename "$0") run proj --docker    # Start with a throwaway sibling Docker daemon
  $(basename "$0") run proj -m . --docker-dev # ... daemon sees /workspace (bind mounts work)
  $(basename "$0") run proj --docker-full # Host socket (host-root-equivalent!)
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
  $(basename "$0") restart my-project -m . # Restart with a new mount, keeping the pi session
  $(basename "$0") restart my-project       # Flags unchanged — plain resume (pi --continue)
  $(basename "$0") restart my-project --fresh # Recreate with a clean pi session
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
# Outputs: NAME|HELP_REQUESTED|INVALID_OPTION|MOUNT_DIR|SSH_FLAG|DEBUG_FLAG|DOCKER_MODE|MISSING_VALUE|FRESH_FLAG
# Field 7 is the --docker MODE string ('' | dind | dind-mount | socket), not a
# yes/no flag: --docker → dind, --docker-dev → dind-mount, --docker-full → socket.
# Field 9 is the restart-only --fresh flag ('yes' forces recreate + fresh session).
extract_name_and_options() {
    local name=""
    local in_mount_value=0
    local help_requested=0
    local invalid_option=0
    local mount_dir=""
    local ssh_flag=""
    local debug_flag=""
    local docker_mode=""
    local missing_value=0
    local fresh_flag=""

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
                # throwaway sibling daemon — the safe default mode
                docker_mode="dind"
                ;;
            --docker-dev)
                docker_mode="dind-mount"
                ;;
            --docker-full)
                docker_mode="socket"
                ;;
            --fresh|--no-continue)
                # restart-only: recreate and start a fresh pi session
                fresh_flag="yes"
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

    echo "${name}|${help_requested}|${invalid_option}|${mount_dir:-}|${ssh_flag:-}|${debug_flag:-}|${docker_mode:-}|${missing_value}|${fresh_flag:-}"
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
        # ':-' guards matter: under 'set -u' an unset SSH_AUTH_SOCK would
        # abort build_docker_args mid-recreate and leave the agent without a
        # container — warn about the missing socket instead.
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
            echo "-v"
            echo "${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock"
            printf '%s\n' "-e"
            echo "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
        else
            log_warn "SSH_AUTH_SOCK is not set or socket not found — SSH agent is not available."
        fi
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

    # Docker access mode. The host socket is mounted ONLY for the
    # explicitly-loud 'socket' mode; 'dind' joins the sibling daemon's network
    # namespace and talks to it over plain TCP — no socket file inside the
    # agent, nothing of the host visible to the daemon (it has no mounts).
    case "${DOCKER_MODE:-}" in
        socket)
            local docker_socket="${DOCKER_SOCKET:-/var/run/docker.sock}"
            if [ -S "$docker_socket" ]; then
                echo "-v"
                echo "${docker_socket}:/var/run/docker.sock"
            else
                log_warn "Docker socket '${docker_socket}' not found — Docker is not available in the container."
            fi
            ;;
        dind|dind-mount)
            echo "--net"
            echo "container:${name}${DIND_SUFFIX}"
            printf '%s\n' "-e" "DOCKER_HOST=tcp://127.0.0.1:2375"
            ;;
    esac

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

###################################################################################################
# DOCKER MODES (--docker / --docker-dev / --docker-full)
###################################################################################################

# Validate a --docker mode. Modes are the safe-by-default trio only; any
# other value (a typo, a mode from a newer pia, ...) fails loudly instead
# of silently degrading into another mode.
validate_docker_mode() {
    case "${1:-}" in
        ""|dind|dind-mount|socket) return 0 ;;
        *)
            log_error "INVALID_DOCKER_MODE: '${1}' — use one of --docker, --docker-dev or --docker-full."
            return 1 ;;
    esac
}

# True when the requested mode runs a throwaway sibling daemon. 'dind' and
# 'dind-mount' differ ONLY in what that daemon may see; netns sharing, labels,
# lifecycle and cleanup are identical, so every lifecycle call site must ask
# this instead of comparing against 'dind'.
dind_mode_active() {
    case "${1:-${DOCKER_MODE:-}}" in
        dind|dind-mount) return 0 ;;
        *) return 1 ;;
    esac
}

# Loud, deliberate banner for the one mode that is host root by design.
# Interactive starts get the warning plus an audit line on stderr; 'pia ask'
# (unattended) refuses the mode outright.
docker_socket_banner() {
    log_warn "────────────────────────────────────────────────────────"
    log_warn "--docker-full: THIS SESSION IS HOST-ROOT-EQUIVALENT."
    log_warn "The agent (and any code it runs) controls the host Docker"
    log_warn "daemon and can escape to root on the host. Prefer '--docker'"
    log_warn "(throwaway sibling daemon). mode=socket name=${1}"
    log_warn "────────────────────────────────────────────────────────"
}

# Banner for 'dind-mount': the one mode that lets the daemon — and therefore
# every container it runs — write into a real host directory. Shorter and
# calmer than the socket banner on purpose: exactly ONE directory becomes
# visible and it is the one the user already handed the agent; everything
# else on the host stays invisible to the daemon.
dind_mount_banner() {
    log_warn "────────────────────────────────────────────────────────"
    log_warn "--docker-dev: the throwaway daemon can read and WRITE"
    log_warn "'${2}'. Nested containers reach it as root, so files they"
    log_warn "leave there are root-owned on the host. That directory is"
    log_warn "the only thing mounted in the daemon — no other path is."
    log_warn "mode=dind-mount ws=${2} name=${1}"
    log_warn "────────────────────────────────────────────────────────"
}

# Resolve the directory 'dind-mount' may mount into the daemon (prints the
# absolute host path). The mode is meaningless without a '-m' workspace, so
# it is refused rather than silently degrading into plain 'dind'.
resolve_dind_workspace() {
    if [ -z "${MOUNT_DIR:-}" ]; then
        log_error "--docker-dev needs a workspace: pass -m <dir>."
        return 1
    fi
    if [ ! -d "$MOUNT_DIR" ]; then
        log_error "Mount directory '${MOUNT_DIR}' does not exist."
        return 1
    fi
    # Same resolution build_docker_args uses for the AGENT mount: the daemon
    # must see the workspace at the SAME path ('/workspace') or the agent's
    # nested '-v /workspace/...' requests would not resolve.
    (cd "$MOUNT_DIR" && pwd)
}

# Name of the throwaway daemon container belonging to an agent.
dind_name_for() {
    echo "${1}${DIND_SUFFIX}"
}

# Strongest OCI runtime available on this host for the throwaway daemon:
# sysbox first (unprivileged nested dind, best compatibility), then gVisor
# (userspace kernel, strongest syscall boundary), else plain runc — where
# nested dind only works at all with --privileged (see dind_create_args)
# and shares the host kernel either way.
detect_dind_runtime() {
    local runtimes
    runtimes="$(docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null || true)"
    case " ${runtimes} " in
        *" sysbox-runc "*) echo "sysbox-runc" ;;
        *" runsc "*)       echo "runsc" ;;
        *)                 echo "" ;;
    esac
}

# Wait until the daemon answers 'docker version' from inside its own
# container. Probing via 'docker exec' needs no published port — and nothing
# outside the sibling's network namespace can reach 2375 either.
wait_dind_ready() {
    local dind="$1" i
    for i in $(seq 1 60); do
        container_is_running "$dind" || return 1
        if docker exec "$dind" docker version > /dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# ── nested-container guard ───────────────────────────────────────
# The daemon container is root on the shared kernel (plain-runc hosts run it
# --privileged just to make nested containers start at all). The guard closes
# the paths that let a NESTED container widen past the session — without a
# kernel exploit:
#   * --privileged / --cap-add SYS_ADMIN|SYS_PTRACE|... (raw disks, virtiofs
#     shares, ptrace of dockerd itself)
#   * --pid/--net/--ipc/--uts=host or container: (namespace joins)
#   * binds of daemon-internal paths (containerd state, overlayfs, runtime
#     binaries — the tamper route that defeats any API-only policy)
# It is installed AS the daemon's runc, so every create lands on it — even
# '--runtime=runc' — and delegates to the real binary at '$0.real'. The
# docker CLI swallows runtime stderr, so refusals also go to
# /var/log/pia-dind-guard.log inside the daemon.
#
# The policy script is a REAL file (docker/pia-dind/guard.sh): BAKED into
# the pia-dind image (which build-docker.sh builds from that folder) and
# installed as the daemon's runc by the image entrypoint. The host copy is
# how pia.sh learns the policy version — it derives the daemon image tag
# and the recreate threshold from it, and never builds. Resolution order:
#   1. $PIA_DIND_GUARD_FILE  (tests, power users)
#   2. <pia dir>/../docker/pia-dind/guard.sh   (running from a checkout)
#   3. ~/.pia/lib/pia-dind/guard.sh            (installed by install-pia.sh)
pia_script_dir() {
    local self
    # BASH_SOURCE[0] is the file the function was DEFINED in — pia.sh — even
    # when tests source it, where '$0' would point at the test script.
    self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null)" || self="${BASH_SOURCE[0]:-$0}"
    dirname -- "$self"
}

dind_guard_file() {
    local cand
    if [ -n "${PIA_DIND_GUARD_FILE:-}" ] && [ -r "$PIA_DIND_GUARD_FILE" ]; then
        printf '%s\n' "$PIA_DIND_GUARD_FILE"
        return 0
    fi
    for cand in "$(pia_script_dir)/../docker/pia-dind/guard.sh" "$HOME/.pia/lib/pia-dind/guard.sh"; do
        if [ -r "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

# The policy version is whatever the guard file declares — single source of
# truth, so bumping it is a one-line edit in docker/pia-dind/guard.sh.
dind_guard_version() {
    local f
    f="$(dind_guard_file)" || return 1
    sed -n 's/^# pia-dind-guard GUARD_VERSION=\(.*\)/\1/p' "$f" | head -1
}

# The daemon image reference: the locally BUILT pia-dind image, tagged with
# the guard policy version — so changing the guard policy changes the tag,
# which forces a rebuild and makes old daemons (older tag, older marker)
# recreate. PIA_DIND_IMAGE overrides the whole reference: pia then uses it
# verbatim, never builds, and verification is the only gate (fail-closed).
dind_image_ref() {
    if [ -n "${PIA_DIND_IMAGE:-}" ]; then
        printf '%s\n' "$PIA_DIND_IMAGE"
        return 0
    fi
    local v
    v="$(dind_guard_version)" || return 1
    [ -n "$v" ] || return 1
    printf '%s\n' "${DIND_IMAGE_DEFAULT}:guard-v$v"
}

# Ensure the daemon image exists locally. The CLI NEVER BUILDS: the
# pia-dind image is produced by scripts/build-docker.sh, in the same pass
# as the agent image — and that agent image is itself only obtainable
# there, so a usable CLI already implies both images were built. A missing
# daemon image is therefore a setup problem, named as such (fail-closed).
# A user-provided PIA_DIND_IMAGE is the exception: it is a normal (pullable)
# image reference, so pulling it on demand is expected behavior — and
# guard verification still gates whatever it points at.
ensure_dind_image() {
    local ref
    ref="$(dind_image_ref)" || {
        log_error "Cannot determine the guard policy version — is docker/pia-dind/guard.sh installed?"
        log_error "Reinstall the CLI: bash harnesses/pia/scripts/install-pia.sh"
        return 1
    }
    docker image inspect "$ref" > /dev/null 2>&1 && return 0
    if [ -n "${PIA_DIND_IMAGE:-}" ]; then
        log_info "Pulling daemon image '${ref}'..."
        if ! docker pull "$ref" > /dev/null 2>&1; then
            log_error "Failed to pull daemon image '${ref}' (override with PIA_DIND_IMAGE)."
            return 1
        fi
        return 0
    fi
    log_error "Daemon image '${ref}' not found locally."
    log_error "Build it (together with the agent image): bash harnesses/pia/scripts/build-docker.sh"
    return 1
}

# True when the running daemon may be REVIVED. Two independent checks:
#   * CONTENT (state): the effective runc still carries the expected guard
#     marker and jq is present — catches tampering with the container's
#     writable layer (runc swapped for a non-guard), which provenance alone
#     would not see, and is the ONLY real gate for a PIA_DIND_IMAGE we did
#     not build.
#   * FINGERPRINT (provenance): the daemon was created from the CURRENT
#     image — docker assigns a new image id on every rebuild, so a stale
#     daemon is caught EVEN IF the policy version string was not bumped.
#     This is why the version marker is provenance, not the decision: the
#     "remember to bump the number" footgun is gone.
dind_guard_ok() {
    local v
    v="$(dind_guard_version)" || return 1
    [ -n "$v" ] || return 1
    docker exec "$1" grep -qs "GUARD_VERSION=$v" /usr/local/bin/runc > /dev/null 2>&1 && \
        docker exec "$1" test -x /usr/bin/jq > /dev/null 2>&1 && \
        dind_daemon_image_current "$1"
}

# Fingerprint check for the BUILT image path: container's image id must
# equal the current 'pia-dind:guard-v<N>' image id. A user-provided
# PIA_DIND_IMAGE is never rebuilt by us, so id equality says nothing there
# — the content checks in dind_guard_ok are the gate for it.
dind_daemon_image_current() {
    [ -n "${PIA_DIND_IMAGE:-}" ] && return 0
    local want have
    want="$(docker image inspect -f '{{.Id}}' "$(dind_image_ref)" 2>/dev/null)" || return 1
    have="$(docker container inspect -f '{{.Image}}' "$1" 2>/dev/null)" || return 1
    [ -n "$want" ] && [ "$want" = "$have" ]
}

# Post-start tamper-proofing of the DAEMON BINARIES the entrypoint could not
# reach: it runs before dockerd, but the dind machinery downloads containerd
# during startup, and docker 29 embeds containerd in dockerd — so pin
# whatever the running processes ACTUALLY executed (readlink /proc/*/exe),
# plus the usual /usr/local/bin names. The guard files themselves are made
# immutable by the image entrypoint (they exist before dockerd starts).
harden_dind_toolchain() {
    docker exec "$1" sh -c '
        for d in /proc/[0-9]*; do
            e=$(readlink "$d/exe" 2>/dev/null) || continue
            case "$e" in *dockerd*|*containerd*|*docker-proxy*) ;; *) continue ;; esac
            [ -f "$e" ] || continue
            chattr +i "$e" 2>/dev/null || true
        done
        for t in dockerd containerd containerd-shim-runc-v2 docker-init docker-proxy docker docker-entrypoint.sh; do
            [ -e "/usr/local/bin/$t" ] && chattr +i "/usr/local/bin/$t" 2>/dev/null || true
        done
    ' > /dev/null 2>&1 || true
}

# Build the 'docker run' arguments for a throwaway daemon, one per line (the
# same convention as build_docker_args, so the test suite can assert on them
# without touching Docker). Args: <daemon-name> <agent-name> <workspace>
# <runtime>.
#
# The daemon gets NO host filesystem mounts by default: build contexts stream
# over TCP from the agent's docker client, so the daemon's MOUNTED view of
# the host is empty. (Reach is a separate question: with sysbox/gVisor the
# two coincide; on plain runc the privileged fallback can mount host disks —
# see the threat model in docs/docker.md.) The one mount exception is
# 'dind-mount': its third argument is the resolved workspace path — exactly
# one bind, at the same path the agent sees, and rprivate so mounts created
# inside nested containers can never propagate back into the host mount
# namespace.
dind_create_args() {
    local dind="$1" agent="$2" workspace="$3" runtime="$4"
    local label

    echo "--name"
    echo "$dind"
    while IFS= read -r label; do echo "$label"; done < <(project_labels "$dind")
    echo "--label"; echo "pia-role=dind"
    echo "--label"; echo "pia-parent=${agent}"
    # The host paths this daemon may see, recorded because binds are frozen
    # at creation: the revive path compares it with the request and
    # recreates on a mismatch instead of silently keeping the old view.
    echo "--label"; echo "pia-dind-mounts=${workspace}"

    if [ -n "$runtime" ]; then
        echo "--runtime"; echo "$runtime"
    else
        # Plain runc host (no sysbox/gVisor) — e.g. Docker Desktop on macOS.
        # --privileged is not a style choice here, it is the ONLY
        # configuration in which nested containers start at all (verified on
        # Docker Desktop, linuxkit 7.0.14/arm64, with docker:29-dind /
        # runc 1.5.2 and with crun):
        #   * the outer default seccomp profile answers
        #     keyctl(KEYCTL_JOIN_SESSION_KEYRING) with EPERM (Docker's
        #     mitigation for the session-keyring kernel CVEs). Seccomp is
        #     inherited and can only be tightened, so NO inner flag can
        #     undo it — every nested 'docker run' dies with 'unable to join
        #     session keyring' unless the DAEMON container itself escapes
        #     the profile (privileged = seccomp unconfined).
        #   * /proc/sys is mounted read-only in an unprivileged container,
        #     so the nested daemon cannot set up bridge networking (the
        #     per-interface disable_ipv6 sysctl write fails).
        # An enumerated-caps fallback was tried first and runs NOTHING on
        # such hosts, so it is gone; privileged is also the documented
        # upstream requirement for docker:dind. This is host-kernel root:
        # a loud warning is printed at startup. It also erases the
        # filesystem boundary — a nested --privileged -v /dev:/dev
        # container can mount the host disks outright, and on Docker
        # Desktop the daemon's CAP_SYS_ADMIN alone can mount the VM's
        # virtiofs tags (all macOS file-sharing folders, /Users included,
        # read-write; verified). For a real boundary install sysbox or
        # gVisor. See the threat model in docs/docker.md.
        echo "--privileged"
    fi

    # 'dind-mount': the workspace, at the agent's own path, read-write.
    if [ -n "$workspace" ]; then
        echo "-v"
        echo "${workspace}:${DIND_WS_TARGET}:rprivate"
    fi

    # Unauthenticated plain TCP inside the shared network namespace only;
    # the port is never published on the host. Anything in the agent's netns
    # controls THIS daemon — accepted: the agent owns it, that is the point.
    # DOCKER_TLS_CERTDIR='' stops the dind image from generating TLS certs
    # and listening on 2376, and --tls=false is the explicit intent dockerd
    # demands for an unauthenticated socket (it otherwise slows startup and
    # deprecation-warns). The in-container client uses the unix socket.
    # (printf, not echo: 'echo "-e"' would be swallowed as an echo flag)
    printf '%s\n' "-e"
    echo "DOCKER_TLS_CERTDIR="
    # The bind whitelist the image entrypoint writes into the guard's conf:
    # dind-mount passes the workspace target inside the daemon, plain dind
    # nothing (Docker plumbing only). Mode is decided here, enforcement is
    # the guard's.
    printf '%s\n' "-e"
    echo "PIA_GUARD_WS=${workspace:+$DIND_WS_TARGET}"
    echo "$(dind_image_ref)"
    echo "dockerd"
    echo "--host=unix:///var/run/docker.sock"
    # Loopback, not 0.0.0.0. The agent reaches the API
    # through the SHARED netns (127.0.0.1:2375) and the in-daemon client
    # uses the unix socket — but nested containers get their own netns, so
    # they can no longer dial the daemon API directly through the bridge.
    # (Published-port forwarding still works: docker-proxy dials loopback.)
    echo "--host=tcp://127.0.0.1:2375"
    echo "--tls=false"
}

# Create (or revive) the throwaway daemon sibling of an agent and wait until
# its API answers. Second argument is the workspace to bind into the daemon
# ('dind-mount' only; empty = the daemon sees nothing of the host — see
# dind_create_args). This is the pia CLI's job — the agent must never be
# able to spawn its own daemon, and the entrypoint only ever waits for one
# that already exists.
start_dind_sibling() {
    local name="$1"
    local workspace="${2:-}"
    local dind image runtime existing_ws
    dind="$(dind_name_for "$name")"
    if ! image="$(dind_image_ref)"; then
        log_error "Cannot determine the daemon image — guard policy version unavailable."
        log_error "Reinstall the CLI: bash harnesses/pia/scripts/install-pia.sh"
        return 1
    fi

    if container_exists "$dind"; then
        if [ "$(docker container inspect -f '{{ index .Config.Labels "pia-role" }}' "$dind" 2>/dev/null)" != "dind" ]; then
            log_error "Container '${dind}' exists but is not a pia daemon sibling — refusing to touch it."
            return 1
        fi
        existing_ws="$(docker container inspect -f '{{ index .Config.Labels "pia-dind-mounts" }}' "$dind" 2>/dev/null)"
        if [ "$existing_ws" != "$workspace" ]; then
            # Reviving would keep the OLD view (binds cannot be changed) —
            # either leaking a stale host directory or silently ignoring the
            # workspace the user just asked for. Recreate instead.
            log_info "Daemon '${dind}' has a different workspace ('${existing_ws:-none}'); recreating it."
            log_cmd "docker rm -f -v ${dind}"
            docker rm -f -v "$dind" > /dev/null 2>&1 || true
        else
            if ! container_is_running "$dind"; then
                log_cmd "docker start ${dind}"
                if ! docker start "$dind" > /dev/null 2>&1; then
                    log_error "Failed to start daemon container '${dind}'."
                    return 1
                fi
            fi
            if wait_dind_ready "$dind"; then
                if dind_guard_ok "$dind"; then
                    return 0
                fi
                # Stale policy (older image), or a tampered/unguarded layer:
                # never revive it, recreate from the current image.
                log_info "Daemon '${dind}' is not the current guarded daemon — recreating it."
                log_cmd "docker rm -f -v ${dind}"
                docker rm -f -v "$dind" > /dev/null 2>&1 || true
            else
                log_error "Daemon '${dind}' is running but its API never answered — see 'docker logs ${dind}'."
                return 1
            fi
        fi
    fi

    if ! ensure_dind_image; then
        return 1
    fi

    runtime="$(detect_dind_runtime)"
    if [ -n "$runtime" ]; then
        log_info "Throwaway daemon '${dind}' using runtime '${runtime}'."
    else
        log_warn "No sysbox/gVisor runtime found — the throwaway daemon runs PRIVILEGED"
        log_warn "on plain runc and SHARES THE HOST KERNEL. Nested containers cannot"
        log_warn "start without privileged there; the nested-container guard (installed"
        log_warn "with the daemon) refuses privileged/capped escapes, but a kernel or"
        log_warn "daemon exploit still reaches the host (on Docker Desktop: this VM,"
        log_warn "and its virtiofs shares if a guard policy gap ever opens). Install"
        log_warn "sysbox or gVisor for a real boundary, or run untrusted workloads"
        log_warn "with no --docker at all."
    fi

    local args=()
    local a
    while IFS= read -r a; do args+=("$a"); done < <(dind_create_args "$dind" "$name" "$workspace" "$runtime")

    log_cmd "docker run -d ${args[*]}"
    if ! docker run -d "${args[@]}" > /dev/null; then
        log_error "Failed to create daemon container '${dind}'."
        return 1
    fi

    if ! wait_dind_ready "$dind"; then
        log_error "Daemon '${dind}' did not become ready — see 'docker logs ${dind}'."
        docker stop "$dind" > /dev/null 2>&1 || true
        docker rm "$dind" > /dev/null 2>&1 || true
        return 1
    fi
    # The image entrypoint already installed the guard and pinned its
    # files; verify it (a PIA_DIND_IMAGE without the guard must never
    # serve), then pin the binaries that only exist post-startup.
    harden_dind_toolchain "$dind"
    if ! dind_guard_ok "$dind"; then
        log_error "Daemon '${dind}' does not carry guard v$(dind_guard_version) — refusing to use it."
        log_error "Image '${image}' is not a built pia-dind image (PIA_DIND_IMAGE override?)."
        docker stop "$dind" > /dev/null 2>&1 || true
        docker rm "$dind" > /dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# Validate the --docker MODE and its workspace argument, resolving the
# 'dind-mount' workspace into DIND_WS. Called BEFORE any Docker work: a bad
# mode or a missing '-m' is a usage error and must not be reported as a
# missing image or a container conflict.
validate_docker_request() {
    validate_docker_mode "${DOCKER_MODE:-}" || return 1
    DIND_WS=""
    if [ "${DOCKER_MODE:-}" = "dind-mount" ]; then
        DIND_WS="$(resolve_dind_workspace)" || return 1
    fi
    return 0
}

# Shared --docker setup for run/create/restart: show the matching banner and
# start the sibling daemon BEFORE the agent (the agent joins its netns).
# 'socket' needs no daemon at all — the host socket is mounted by
# build_docker_args instead. Assumes validate_docker_request already ran.
prepare_dind_daemon() {
    local name="$1"
    if [ "${DOCKER_MODE:-}" = "socket" ]; then
        docker_socket_banner "$name"
        return 0
    fi
    if [ "${DOCKER_MODE:-}" = "dind-mount" ]; then
        dind_mount_banner "$name" "$DIND_WS"
    fi
    if dind_mode_active; then
        start_dind_sibling "$name" "$DIND_WS" || return 1
    fi
    return 0
}

# List the daemon siblings belonging to an agent: the pia-parent label is
# authoritative, the name convention is fallback; anything accepted must
# carry pia-role=dind so a user container that merely LOOKS like a sibling
# is never touched. (After 'pia rename' the label still points at the old
# name — the name-convention fallback covers the standard case.)
dind_siblings_for() {
    local name="$1"
    local cand role parent
    for cand in "$(dind_name_for "$name")" \
                "$(docker ps -a --filter "label=pia-parent=${name}" --format '{{.Names}}' 2>/dev/null)"; do
        [ -n "$cand" ] || continue
        container_exists "$cand" || continue
        role="$(docker container inspect -f '{{ index .Config.Labels "pia-role" }}' "$cand" 2>/dev/null)"
        [ "$role" = "dind" ] || continue
        parent="$(docker container inspect -f '{{ index .Config.Labels "pia-parent" }}' "$cand" 2>/dev/null)"
        if [ "$parent" = "$name" ] || [ "$cand" = "$(dind_name_for "$name")" ]; then
            echo "$cand"
        fi
    done | sort -u
}

stop_dind_siblings() {
    local s
    for s in $(dind_siblings_for "$1"); do
        log_cmd "docker stop ${s}"
        docker stop "$s" > /dev/null 2>&1 || true
    done
}

# '-v' also discards the daemon's storage (built images, pulled layers) —
# nothing in there is worth keeping once the agent is gone.
remove_dind_siblings() {
    local s
    for s in $(dind_siblings_for "$1"); do
        log_cmd "docker rm -f -v ${s}"
        docker rm -f -v "$s" > /dev/null 2>&1 || true
    done
}

# Bring an agent's daemon back up before (re)attaching a session: the agent
# shares the daemon's network namespace, so it cannot start while a stopped
# daemon owns that netns — and its DOCKER_HOST would point at nothing.
ensure_dind_siblings_started() {
    local name="$1" s ready
    for s in $(dind_siblings_for "$name"); do
        ready=""
        if ! container_is_running "$s"; then
            log_info "Starting daemon container '${s}'..."
            log_cmd "docker start ${s}"
            docker start "$s" > /dev/null 2>&1 || { log_warn "Failed to start daemon '${s}'."; continue; }
        fi
        wait_dind_ready "$s" && ready="yes"
        if [ -n "$ready" ] && ! dind_guard_ok "$s"; then
            # Never keep a daemon whose layer predates the current guard
            # policy — it may already be tampered with. Recreate it with the
            # workspace recorded on its own label (its images are lost).
            local ws
            ws="$(docker container inspect -f '{{ index .Config.Labels "pia-dind-mounts" }}' "$s" 2>/dev/null)"
            log_warn "Daemon '${s}' lacks the current guard policy — recreating it (images in it are lost)."
            docker rm -f -v "$s" > /dev/null 2>&1 || true
            start_dind_sibling "$name" "$ws" || return 1
            continue
        fi
        [ -n "$ready" ] || log_warn "Daemon '${s}' is running but its API is not answering."
    done
    # Agent created against a sibling that no longer exists: docker calls
    # inside would fail with a confusing connection error — say it plainly.
    if [ -z "$(dind_siblings_for "$name")" ] && \
       docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null | \
       grep -q '^DOCKER_HOST=tcp://127\.0\.0\.1:2375$'; then
        log_warn "Container '${name}' expects a throwaway daemon but has none — docker calls will fail."
        log_warn "Recreate it with 'pia restart ${name} --docker' (or --docker-dev with a workspace)."
    fi
}

# Warn when a RUNNING agent's throwaway daemon is stopped: the guard's kill
# switch exits the daemon container on purpose, and because the
# agent shares its netns, the agent's docker access AND its network die
# with it. Both halves need restarting, in order, until 'pia revive' wraps
# this.
warn_dind_dead() {
    local name="$1" dind why
    dind="$(dind_name_for "$name")"
    container_exists "$dind" || return 0
    container_is_running "$dind" && return 0
    container_is_running "$name" || return 0
    why="the daemon was stopped or crashed"
    if docker cp "${dind}:/var/log/pia-dind-guard.log" - 2>/dev/null | tar -xO 2>/dev/null | \
        grep -q "killing dockerd"; then
        why="the guard kill switch fired on a daemon-side mount refusal — BY DESIGN"
    fi
    log_warn "Daemon '${dind}' is stopped while the agent runs: nested docker AND the agent's network are dead (${why})."
    log_warn "Investigate: pia dindlog ${name#pia-}"
    log_warn "Recover BOTH halves in order: docker start ${dind} && docker restart ${name}  (planned: 'pia revive')."
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

# Last-resort cleanup while a blocking session command ('docker exec ... pi')
# is running. Closing the terminal (or Ctrl+C / a plain kill) sends HUP/INT/TERM
# to this script as well as to the docker client; without a handler the script
# dies before the post-exec cleanup and the detached container is orphaned.
# Trap those signals, run CLEANUP (shell code the caller built with the pinned
# container ID, so a mid-session rename cannot defeat it), then die. SIGKILL
# (kill -9) cannot be caught — that case stays a known gap; only an ENTRYPOINT
# that is pi itself covers it.
trap_session_signals() {
    local cleanup="$1"
    trap "$cleanup; exit 1" HUP INT TERM
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
    trap_session_signals "docker stop '$id' > /dev/null 2>&1"
    docker exec ${exec_args} "$id" pi || rc=$?
    trap - HUP INT TERM

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
    trap_session_signals "docker stop '$id' > /dev/null 2>&1"
    docker exec ${exec_args} "$id" pi --continue || rc=$?
    trap - HUP INT TERM

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
# SESSION-PRESERVING RESTART (issue #15)
###################################################################################################

# Where pi keeps its conversation state inside the container (the image runs
# as root). Recreating the container throws the whole filesystem away, so a
# session-preserving restart copies this directory (plus the 'pia urls'
# request log) out before 'docker rm' and back into the new container, then
# starts 'pi --continue' — the conversation survives, the rest does not.
PI_SESSIONS_DIR="/root/.pi/agent/sessions"
PI_URLS_LOG="/var/log/pia-urls.log"

# The container's CURRENT run options as 'MOUNT|SSH|DOCKER_MODE', derived from
# what Docker actually has (mounts, env, daemon sibling) — the config-hash
# label is a per-create nonce, not a config digest, so the live inspect data
# is the honest comparison base for 'restart'.
container_run_config() {
    local name="$1"
    local mount ssh="" mode="" dind ws

    mount="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$name" 2>/dev/null)"

    if docker container inspect -f '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' "$name" 2>/dev/null | \
       grep -qx '/tmp/ssh-agent.sock'; then
        ssh="yes"
    fi

    if docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null | \
       grep -q '^DOCKER_HOST=tcp://127\.0\.0\.1:2375$'; then
        # 'dind' vs 'dind-mount' is invisible on the agent itself — the
        # difference is what the daemon may see, recorded on its own label.
        mode="dind"
        dind="$(dind_siblings_for "$name" | head -1)"
        if [ -n "$dind" ]; then
            ws="$(docker container inspect -f '{{ index .Config.Labels "pia-dind-mounts" }}' "$dind" 2>/dev/null)"
            if [ -n "$ws" ] && [ "$ws" != "<no value>" ]; then mode="dind-mount"; fi
        fi
    elif docker container inspect -f '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' "$name" 2>/dev/null | \
         grep -qx '/var/run/docker.sock'; then
        mode="socket"
    fi

    echo "${mount:-}|${ssh}|${mode}"
}

# Copy the pi session state (and the urls request log) out of a container
# into a fresh host temp dir. Prints the dir path, or nothing when the
# container has no session directory (nothing to continue).
save_session_state() {
    local name="$1"
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pia-session-XXXXXX")" || return 0
    if ! docker cp "${name}:${PI_SESSIONS_DIR}" "${tmp}/sessions" > /dev/null 2>&1; then
        rm -rf "$tmp"
        return 0
    fi
    # Best effort — an image without the request logger simply has no log.
    docker cp "${name}:${PI_URLS_LOG}" "${tmp}/pia-urls.log" > /dev/null 2>&1 || true
    echo "$tmp"
}

# Copy a saved session (and request log) back into the freshly created,
# already-started container, then discard the temp dir. Returns 0 only when
# the session directory itself made it in — that is what gates 'pi --continue'.
restore_session_state() {
    local name="$1" tmp="$2"
    [ -n "$tmp" ] && [ -d "$tmp" ] || return 1

    local rc=0
    if docker exec "$name" mkdir -p "$PI_SESSIONS_DIR" > /dev/null 2>&1; then
        # '/.' copies the CONTENTS into the existing directory (a plain
        # 'docker cp dir dir' would nest it as dir/dir).
        docker cp "${tmp}/sessions/." "${name}:${PI_SESSIONS_DIR}/" > /dev/null 2>&1 || rc=1
    else
        rc=1
    fi
    if [ -f "${tmp}/pia-urls.log" ]; then
        docker cp "${tmp}/pia-urls.log" "${name}:${PI_URLS_LOG}" > /dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
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
    DOCKER_MODE="$(echo "$result" | cut -d'|' -f7)"

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

    # '--fresh' is a restart-only escape hatch; create always starts clean.
    if [ "$(echo "$result" | cut -d'|' -f9)" = "yes" ]; then
        log_error "Option '--fresh' applies to 'restart' only."
        exit 1
    fi

    # Usage-level --docker checks (mode + workspace) come first, before any
    # container or image is touched.
    validate_docker_request || exit 1

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

    # --docker modes: validate, warn loudly for 'socket', and bring up the
    # throwaway daemon BEFORE the agent — the agent joins its netns.
    prepare_dind_daemon "$name" || exit 1

    # Create (without starting)
    log_info "Creating agent container '${name}' from image '${IMAGE_NAME}' (not started)..."
    local docker_args=()
    while IFS= read -r arg; do
        docker_args+=("$arg")
    done < <(build_docker_args "$name")

    local docker_cmd="docker create ${docker_args[*]}"
    log_cmd "$docker_cmd"
    if ! docker create "${docker_args[@]}" > /dev/null; then
        if dind_mode_active; then remove_dind_siblings "$name"; fi
        log_error "Failed to create container '${name}'."
        log_error "Make sure the image '${IMAGE_NAME}' exists. Run './scripts/build-docker.sh' first."
        exit 1
    fi

    # Both halves stay stopped — a running daemon idling behind a stopped
    # agent would go unnoticed. 'pia run NAME' / 'pia ask NAME' start it.
    if dind_mode_active; then stop_dind_siblings "$name"; fi

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
    DOCKER_MODE="$(echo "$result" | cut -d'|' -f7)"

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

    # '--fresh' is a restart-only escape hatch; run always creates fresh.
    if [ "$(echo "$result" | cut -d'|' -f9)" = "yes" ]; then
        log_error "Option '--fresh' applies to 'restart' only."
        exit 1
    fi

    # Usage-level --docker checks (mode + workspace) come first, before any
    # container or image is touched.
    validate_docker_request || exit 1

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
            warn_dind_dead "$name"
            exit 1
        else
            log_info "Container '${name}' exists but is stopped. Starting it..."
            # --docker is a creation-time option: this container already has
            # its netns, its DOCKER_HOST and its daemon bind baked in. Warn
            # only when the request actually contradicts what exists, so the
            # ordinary 'pia run NAME --docker' on a dind container stays
            # quiet instead of nagging about a mode that is already in place.
            if [ -n "${DOCKER_MODE:-}" ]; then
                local created_dind=""
                if docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null | \
                   grep -q '^DOCKER_HOST=tcp://127\.0\.0\.1:2375$'; then
                    created_dind="yes"
                fi
                if { [ -n "$created_dind" ] && ! dind_mode_active; } || \
                   { [ -z "$created_dind" ] && [ -n "${DOCKER_MODE:-}" ]; }; then
                    log_warn "Container '${name}' was created with a different --docker mode — it is unchanged."
                    local mode_flag="--docker"
                    case "${DOCKER_MODE:-}" in
                        dind-mount) mode_flag="--docker-dev" ;;
                        socket)   mode_flag="--docker-full" ;;
                    esac
                    log_warn "Recreate it with 'pia restart ${name} ${mode_flag}'."
                fi
            fi
            # A dind-mode agent shares its daemon's netns: the daemon must
            # be up before 'docker start' of the agent can succeed at all.
            ensure_dind_siblings_started "$name"
            local exit_code=0
            attach_session "$name" || exit_code=$?
            stop_dind_siblings "$name"
            exit $exit_code
        fi
    fi

    # Validate image exists
    if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
        log_error "Image '${IMAGE_NAME}' not found."
        log_error "Build it first: cd ../docker && ./build-docker.sh"
        exit 1
    fi

    # --docker modes: validate, warn loudly for 'socket', and bring up the
    # throwaway daemon BEFORE the agent — the agent joins its netns.
    prepare_dind_daemon "$name" || exit 1

    # Build and run
    log_info "Starting agent container '${name}' from image '${IMAGE_NAME}'..."
    local docker_args=()
    while IFS= read -r arg; do
        docker_args+=("$arg")
    done < <(build_docker_args "$name")

    local docker_cmd="docker run -d ${docker_args[*]}"
    log_cmd "$docker_cmd"
    if ! docker run -d "${docker_args[@]}" > /dev/null; then
        if dind_mode_active; then remove_dind_siblings "$name"; fi
        log_error "Failed to create container '${name}'."
        log_error "Make sure the image '${IMAGE_NAME}' exists. Run './scripts/build-docker.sh' first."
        exit 1
    fi

    # Attach an interactive pi session; the container stops with the session.
    local exit_code=0
    start_session "$name" || exit_code=$?

    # Session ended — the agent container is stopped again; take the
    # throwaway daemon with it (a stray stopped daemon is 'pia clean' bait).
    stop_dind_siblings "$name"

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

    # An agent never outlives its throwaway daemon (and stopping a daemon
    # that does not exist is a silent no-op).
    stop_dind_siblings "$name"

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

    # No agent left behind to own the daemon — it goes too, storage and all.
    remove_dind_siblings "$name"

    log_info "Container '${name}' removed."
}

# 'list' selects no container and takes no arguments — an argument would be
# silently ignored, so reject it instead.
cmd_ls() {
    local extra=""
    local all=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") list [OPTIONS]"
                echo ""
                echo "Lists every agent container (running and stopped)."
                echo ""
                echo "Options:"
                echo "  -a, --all   Also show the throwaway 'dind' daemon containers"
                echo "              (plumbing, hidden by default)"
                echo ""
                echo "Takes no other arguments. For a single container use:"
                echo "  docker ps -a --filter name=^pia-<NAME>"
                exit 0 ;;
            -a|--all)
                all="yes"
                shift ;;
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

    # pia_ps already selects the project and hides daemon plumbing; --all
    # shows the whole pia project including the 'NAME-dind' siblings
    # (tab separators keep Status and CreatedAt fields with spaces intact)
    while IFS=$'\t' read -r id name state created; do
        if [ -z "$id" ]; then continue; fi

        found=1
        printf "%-30s %-10s %s\n" "$name" "$state" "$created"
    done < <(if [ -n "$all" ]; then pia_ps_all; else pia_ps; fi)

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
    DOCKER_MODE="$(echo "$result" | cut -d'|' -f7)"
    local fresh_flag
    fresh_flag="$(echo "$result" | cut -d'|' -f9)"

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

    # Usage-level --docker checks (mode + workspace) come first.
    validate_docker_request || exit 1

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

    # Decide what 'restart' means for this call (issue #15): options the
    # caller did NOT pass keep the container's current values, so plain
    # 'pia restart NAME' never recreates. Only options that actually
    # CONTRADICT the container config force a recreate — mounts, the SSH
    # socket and the network namespace are fixed at creation (Docker cannot
    # patch them on an existing container).
    local cur_mount cur_ssh cur_mode
    IFS='|' read -r cur_mount cur_ssh cur_mode < <(container_run_config "$name")

    local flags_changed="" changed_list=""
    if [ -n "$MOUNT_DIR" ]; then
        local req_mount
        req_mount="$(cd "$MOUNT_DIR" && pwd)"
        if [ "$req_mount" != "$cur_mount" ]; then
            flags_changed="yes"; changed_list="mount"
        fi
    fi
    if [ -n "$SSH_FLAG" ] && [ -z "$cur_ssh" ]; then
        flags_changed="yes"; changed_list="${changed_list:+$changed_list, }ssh"
    fi
    if [ -n "$DOCKER_MODE" ] && [ "$DOCKER_MODE" != "$cur_mode" ]; then
        flags_changed="yes"; changed_list="${changed_list:+$changed_list, }--docker mode"
    fi

    if [ "$fresh_flag" != "yes" ] && [ -z "$flags_changed" ]; then
        # ---- Resume path: run flags unchanged — same container, same pi
        # conversation. Identical to 'pia run NAME' / 'pia resume', plus the
        # bounce when the container is currently running.
        if container_is_running "$name"; then
            log_info "Run flags unchanged — bouncing container '${name}' and continuing its last pi session..."
            log_cmd "docker stop ${name}"
            docker stop "$name" > /dev/null 2>&1 || true
            stop_dind_siblings "$name"
        else
            log_info "Run flags unchanged — resuming container '${name}' in place (no recreate)..."
        fi
        ensure_dind_siblings_started "$name"
        local exit_code=0
        attach_session "$name" || exit_code=$?
        stop_dind_siblings "$name"
        if [ $exit_code -eq 0 ]; then
            log_info "Container '${name}' restarted successfully."
        else
            log_error "Container '${name}' exited with code ${exit_code}."
        fi
        exit $exit_code
    fi

    # ---- Recreate path ----
    if [ "$fresh_flag" = "yes" ]; then
        log_info "Re-creating container '${name}' with a FRESH pi session (--fresh)..."
    else
        log_info "Run flags changed (${changed_list}) — container '${name}' must be re-created..."
        log_info "Preserved across the recreate: the pi conversation ('pi --continue') and the 'pia urls' request log."
        log_warn "Reset by the recreate: the container filesystem (packages, edits outside the mount)"
        log_warn "and any throwaway Docker daemon — images built inside it are lost."
    fi

    # Stop the existing container
    log_info "Stopping container '${name}'..."
    log_cmd "docker stop ${name}"
    docker stop "$name" > /dev/null 2>&1 || true

    # Carry the pi session across the recreate — must happen before 'docker
    # rm' takes the container layer with it. Empty when the container has no
    # session state (or --fresh): the new container then starts a clean pi.
    local session_tmp=""
    if [ "$fresh_flag" != "yes" ]; then
        session_tmp="$(save_session_state "$name")"
        if [ -n "$session_tmp" ]; then
            log_info "Pi session state saved — the new container will continue it."
        else
            log_info "No pi session to preserve in '${name}' — the new container starts clean."
        fi
    fi

    # Remove the container
    log_info "Removing container '${name}'..."
    log_cmd "docker rm ${name}"
    docker rm "$name" > /dev/null 2>&1 || true

    # The old daemon goes with the old agent — a restart starts a clean,
    # empty daemon, never a reused one with the previous session's images.
    remove_dind_siblings "$name"

    # Options the caller did not pass carry over from the old container, so
    # 'restart NAME --ssh' on a mounted agent recreates WITH the mount
    # instead of silently dropping it. (--fresh keeps the historical
    # 'unspecified = absent' semantics.)
    if [ "$fresh_flag" != "yes" ]; then
        if [ -z "$MOUNT_DIR" ] && [ -n "$cur_mount" ]; then MOUNT_DIR="$cur_mount"; fi
        if [ -z "$SSH_FLAG" ]; then SSH_FLAG="$cur_ssh"; fi
        if [ -z "$DOCKER_MODE" ] && [ -n "$cur_mode" ]; then
            DOCKER_MODE="$cur_mode"
            validate_docker_request || exit 1
        fi
    fi

    # --docker modes (same order as 'run': daemon first, agent second)
    prepare_dind_daemon "$name" || {
        if [ -n "$session_tmp" ]; then rm -rf "$session_tmp"; fi
        exit 1
    }

    # Start a fresh container with the same name
    log_info "Starting fresh agent container '${name}' from image '${IMAGE_NAME}'..."
    local docker_args=()
    while IFS= read -r arg; do
        docker_args+=("$arg")
    done < <(build_docker_args "$name")

    local docker_cmd="docker run -d ${docker_args[*]}"
    log_cmd "$docker_cmd"
    if ! docker run -d "${docker_args[@]}" > /dev/null; then
        if [ -n "$session_tmp" ]; then rm -rf "$session_tmp"; fi
        if dind_mode_active; then remove_dind_siblings "$name"; fi
        log_error "Failed to create container '${name}'."
        log_error "Make sure the image '${IMAGE_NAME}' exists. Run './scripts/build-docker.sh' first."
        exit 1
    fi

    # Attach an interactive pi session; the container stops with the session.
    # With the saved state restored the session CONTINUES ('pi --continue'
    # via attach_session); otherwise this is the historical fresh start.
    local exit_code=0
    if [ -n "$session_tmp" ] && restore_session_state "$name" "$session_tmp"; then
        log_info "Pi session restored — continuing it with 'pi --continue'."
        attach_session "$name" || exit_code=$?
    else
        start_session "$name" || exit_code=$?
    fi

    # Session ended — daemon stops with the agent (see cmd_run).
    stop_dind_siblings "$name"

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
    warn_dind_dead "$name"

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
# docker/pia/monitor-inside.sh), and naming tshark here would also kill a tshark
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

###################################################################################################
# 'pia monitor' CHARTS — rendering helpers
#
# The samples reach the host one 'docker exec' at a time, so the rolling history
# lives in the globals below (nothing on disk: 'pia monitor' still writes no log
# files, in chart mode or out of it). None of these helpers call docker or read
# files, which is what makes them unit-testable in
# scripts/tests/test-functions.sh.
###################################################################################################

CHART_HISTORY="240"      # samples kept per series (the sparkline shows the last few dozen)
CHART_ROWS="10"          # destination rows in the top-destinations pane, if the terminal is tall enough
CHART_LABEL_WIDTH="30"   # the 'cpu 12.4% of 8 cores' column

# Glyph set, decided once: the eight one-eighth blocks, or an ASCII ramp.
# 'locale charmap' is the check rather than '[[ $LANG == *UTF-8 ]]', which misses
# the LANG unset / LC_ALL=C cases where the blocks would print as mojibake.
chart_init() {
    [ -n "${CHART_GLYPHS[*]:-}" ] && return 0
    case "$(locale charmap 2>/dev/null || echo '')" in
        (UTF-8 | utf8)
            CHART_GLYPHS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
            CHART_EMPTY='░'
            CHART_RULE='─'
            CHART_MID='·'
            CHART_DOWN='↓'
            CHART_UP='↑'
            ;;
        (*)
            # Every glyph quoted: an unquoted '#' would start a comment inside
            # the array assignment and swallow the rest of the case item.
            CHART_GLYPHS=('_' '.' ':' '-' '=' '+' '*' '#')
            CHART_EMPTY='-'
            CHART_RULE='-'
            CHART_MID='-'
            CHART_DOWN='v'
            CHART_UP='^'
            ;;
    esac
}

# Terminal size for the frame, re-read every cycle so a resized window is
# noticed. tput answers nothing (or nothing sensible) when stdout is not a
# terminal, hence the floor — the frame is then drawn for a sane 80x24.
chart_term_size() {
    CHART_COLS="$(tput cols 2>/dev/null || echo 0)"
    CHART_LINES="$(tput lines 2>/dev/null || echo 0)"
    [[ "$CHART_COLS" =~ ^[0-9]+$ ]] && [ "$CHART_COLS" -ge 48 ] || CHART_COLS=80
    [[ "$CHART_LINES" =~ ^[0-9]+$ ]] && [ "$CHART_LINES" -ge 14 ] || CHART_LINES=24
    # Past this the frame would draw a rule across a wall; the extra columns
    # buy no information. An 'if', not '&&': a failing AND-list would be this
    # function's exit status, and 'set -e' in the caller reads that as a fatal
    # error — on every normal terminal.
    if [ "$CHART_COLS" -gt 100 ]; then CHART_COLS=100; fi
}

# Byte counts with a binary suffix — the same ramp the in-container helper
# prints, so a number reads identically in the chart and in line mode.
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b < 0) { printf "-"; b = -b }
        if (b >= 1073741824)   printf "%.1fGiB", b / 1073741824
        else if (b >= 1048576) printf "%.1fMiB", b / 1048576
        else if (b >= 1024)    printf "%.1fKiB", b / 1024
        else                   printf "%dB", b
    }'
}

# Token counts with a decimal k/M suffix (same rule as the helper's
# human_tok): 262144 tokens is 262.1k, never 256KiB — tokens are not bytes.
human_count() {
    awk -v n="${1:-0}" 'BEGIN {
        if (n >= 1000000) printf "%.1fM", n / 1000000
        else if (n >= 1000) printf "%.1fk", n / 1000
        else printf "%d", n
    }'
}

# chart_pad TEXT WIDTH — pad (or truncate, with a '~') to WIDTH columns so the
# chart columns line up. Padding is counted with ${#s} and printed as plain
# spaces, because 'printf %-Ns' counts BYTES and a padded string can well
# contain a three-byte arrow or block glyph.
chart_pad() {
    local s="$1" w="$2"
    [ "$w" -gt 0 ] || return 0
    if [ "${#s}" -gt "$w" ]; then
        printf '%s~' "${s:0:w - 1}"
    else
        printf '%s%*s' "$s" "$(( w - ${#s} ))" ''
    fi
}

# sparkline WIDTH VALUE... — the last at-most-WIDTH values as a sparkline,
# scaled to the maximum of what is shown (so a quiet container that starts
# working still lights up, instead of drawing a flat line at 1% of a peak from
# an hour ago) but to SIX levels, not seven: the topmost block is never drawn,
# so there is always a one-glyph gap above the series. Without it a busy
# container painted a solid line against the top of the row and 'all values
# equal' was indistinguishable from 'pinned at the maximum' — dips only became
# visible once they were measured from an invisible ceiling. awk emits level
# INDICES and bash maps them to glyphs, because mawk splits strings into bytes
# and the blocks are three bytes each.
sparkline() {
    local width="${1:-20}" out="" lv
    shift
    # slots without a sample yet are '.', not blank: the chart reserves its
    # full width from the first cycle (nothing shifts as history grows) and
    # 'no data yet' is something you can see
    [ $# -gt 0 ] || { printf '%*s' "$width" '' | tr ' ' '.'; return 0; }
    for lv in $(printf '%s\n' "$@" | awk -v w="$width" '
        { v[++n] = $1 + 0; if (v[n] < 0) v[n] = 0 }
        END {
            if (n == 0) exit
            s = (n > w) ? n - w + 1 : 1
            m = 0
            for (i = s; i <= n; i++) if (v[i] > m) m = v[i]
            for (i = s; i <= n; i++) printf "%d ", (m > 0) ? int(v[i] / m * 6 + 0.5) : 0
        }'); do
        out+="${CHART_GLYPHS[$lv]}"
    done
    while [ "${#out}" -lt "$width" ]; do out+="."; done
    printf '%s' "$out"
}

# bar WIDTH PCT — a horizontal gauge for a 0..100 percentage, clamped at both
# ends (a cgroup reading can exceed 100 or go negative after a counter reset).
# The fill glyph is the SECOND-tallest block, like the sparkline ceiling: a
# full gauge must not touch the top of its row either, or it welds itself to
# the chart above (cpu's ▇ sitting on mem's █ read as one solid block, while
# mem-over-net, where both leave the ceiling free, showed the small gap the
# rows are meant to have).
bar() {
    local width="${1:-20}" pct="${2:-0}" filled out="" i
    [[ "$width" =~ ^[0-9]+$ ]] || width=20
    filled="$(awk -v p="$pct" -v w="$width" 'BEGIN {
        f = int(p * w / 100 + 0.5); if (f < 0) f = 0; if (f > w) f = w; print f
    }')"
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then out+="${CHART_GLYPHS[6]}"; else out+="$CHART_EMPTY"; fi
    done
    printf '%s' "$out"
}

# --- chart state -------------------------------------------------------------

# Indexed arrays throughout, and 'declare' spelled out: bash 3.2 — still the
# /bin/bash macOS ships — has neither 'declare -A' nor 'local -A', and a
# top-level one aborts the whole CLI at load time, monitor or not. A linear
# lookup costs nothing at the number of destinations a container touches in one
# interval, and it keeps 'pia' runnable where it has always run.
CPU_SERIES=()
MEM_SERIES=()
RX_SERIES=()
TX_SERIES=()
declare -a DEST_LIST=()  # every destination ever seen, in order of first sight
declare -a DEST_TOTAL=() # hits per destination since the monitor started (parallel to DEST_LIST)
declare -a DEST_LAST=()  # the sample number each destination last appeared in
                         # (the pane leads with what is being called NOW)
declare -a DEST_CUR=()   # the destinations of the newest cycle... (parallel with...)
declare -a DEST_CUR_N=() # ... their hits in that cycle
CHART_IDX="-1"           # chart_index's answer

# Numeric patterns for the fields parsed out of a sample. They live in
# variables and are matched as '$re', not written inline: bash 3.2's parser
# for '[[ =~ ]]' — still macOS' /bin/bash — aborts on unquoted parentheses
# in an expression ('syntax error: unexpected token `('), and quoting the
# pattern instead makes it a LITERAL string. A variable operand is the only
# form that parses on every bash and still matches as a regex.
RE_SIGNED_NUM='^-?[0-9]+(\.[0-9]+)?$'  # a counter delta — may go negative after a reset
RE_COUNT='^[0-9]+(\.[0-9]+)?$'         # pids, bytes: never negative
RE_FLOW_COUNT=' x([0-9]+)$'            # the '   x14' repeat-count suffix of a flow line

# series_push NAME VALUE — append to a series and trim it to CHART_HISTORY.
# 'eval' rather than a nameref because bash 4.2 (still shipped on older distros
# and in macOS' /bin/bash) has no 'local -n'.
series_push() {
    local __name="$1" __val="${2:-0}" __len
    [[ "$__val" =~ $RE_SIGNED_NUM ]] || __val=0
    eval "${__name}+=(\"\$__val\")"
    eval "__len=\${#${__name}[@]}"
    if [ "$__len" -gt "$CHART_HISTORY" ]; then
        eval "${__name}=(\"\${${__name}[@]: -$CHART_HISTORY}\")"
    fi
}

# series_spark NAME WIDTH — the sparkline of a series, blank (not an error) while
# it is still empty. The empty-array check is also what keeps '${arr[@]}' from
# tripping 'set -u' on bash older than 4.4.
series_spark() {
    local __name="$1" __w="${2:-20}" __n
    eval "__n=\${#${__name}[@]}"
    [ "${__n:-0}" -gt 0 ] || { printf '%*s' "$__w" '' | tr ' ' '.'; return 0; }
    eval "sparkline \"\$__w\" \"\${${__name}[@]}\""
}

# series_max NAME [FMT] — the largest value a series ever held (0 when it is
# empty), printed with FMT (default '%d' — byte counts; '%.1f' for percents).
# Used for the header's peak cpu/memory figures, the history worth a number.
series_max() {
    local __name="$1" __fmt="${2:-%d}" __n
    eval "__n=\${#${__name}[@]}"
    [ "${__n:-0}" -gt 0 ] || { printf '0'; return 0; }
    eval "printf '%s\n' \"\${${__name}[@]}\"" | awk -v f="$__fmt" 'BEGIN { m = 0 } $1 + 0 > m { m = $1 + 0 } END { printf f, m }'
}

# chart_index LIST KEY — the position of KEY in the named list, left in
# CHART_IDX (-1 when it is not there). The answer is a global rather than stdout
# because a command substitution would fork once per flow line, per cycle, for a
# search that is a handful of string comparisons. Only the array NAME is eval'd
# (always a literal from here); the key stays a quoted variable, so a destination
# with spaces, parentheses or globs in it is compared, never executed.
chart_index() {
    local __list="$1" __key="$2" __i=0 __n=0 __val
    eval "__n=\${#${__list}[@]}"
    while [ "$__i" -lt "$__n" ]; do
        eval "__val=\"\${${__list}[__i]}\""
        if [ "$__val" = "$__key" ]; then
            CHART_IDX="$__i"
            return 0
        fi
        __i=$(( __i + 1 ))
    done
    CHART_IDX="-1"
    return 0
}

# monitor_ingest TEXT — fold one cycle's output into the chart state: the
# '#stats' line into the rolling series, every flow line into the destination
# counters. The human '-- cpu ...' line is dropped on purpose: the frame IS that
# line, drawn as charts. Returns 1 when the sample carried no '#stats' line,
# which means the image inside the container predates charts.
monitor_ingest() {
    local out="$1" line dest n kv stats_line="" value i seq
    local -a words

    DEST_CUR=()
    DEST_CUR_N=()
    # CHART_SAMPLES counts the samples ingested SO FAR, so this cycle is the
    # next number — the stamp DEST_LAST keeps, and the pane sorts by.
    seq=$(( ${CHART_SAMPLES:-0} + 1 ))
    while IFS= read -r line; do
        case "$line" in
            ('#stats '*) stats_line="$line"; continue ;;
            ('-- cpu '* | '') continue ;;
        esac
        # A flow line is '<time>  <what>' — drop the timestamp. A line without
        # the two-space separator is neither a flow nor a sample (a stray
        # warning, say) and is ignored rather than counted as a destination.
        dest="${line#*  }"
        [ "$dest" != "$line" ] || continue
        n=1
        if [[ "$dest" =~ $RE_FLOW_COUNT ]]; then
            n="${BASH_REMATCH[1]}"
            dest="${dest%"${BASH_REMATCH[0]}"}"
        fi
        # The counter is separated by its own run of spaces ('<what>   x3'), so
        # stripping it leaves trailing blanks — they would make the same
        # destination two different keys when one cycle repeats it and another
        # does not.
        dest="${dest%"${dest##*[![:space:]]}"}"
        chart_index DEST_CUR "$dest"
        if [ "$CHART_IDX" -ge 0 ]; then
            DEST_CUR_N[$CHART_IDX]=$(( ${DEST_CUR_N[$CHART_IDX]} + n ))
        else
            DEST_CUR+=("$dest")
            DEST_CUR_N+=("$n")
        fi
        chart_index DEST_LIST "$dest"
        if [ "$CHART_IDX" -ge 0 ]; then
            DEST_TOTAL[$CHART_IDX]=$(( ${DEST_TOTAL[$CHART_IDX]} + n ))
            DEST_LAST[$CHART_IDX]="$seq"
        else
            DEST_LIST+=("$dest")
            DEST_TOTAL+=("$n")
            DEST_LAST+=("$seq")
        fi
    done <<< "$out"

    [ -n "$stats_line" ] || return 1

    # '#stats cpu=1.2 cores=8 mem=... mem_max=max pids=12 rx=... tx=... secs=3
    #         tok_in=... tok_cache=... tok_out=... tok_cost=...'
    # (the tok_* fields are cumulative across ALL pi sessions the container
    # stores, with input split into uncached and cached like pi's /usage; an
    # image built before tokens existed simply omits them and the tok row
    # shows 'tok ?')
    read -r -a words <<< "${stats_line#'\#stats '}"
    i=0
    while [ "$i" -lt "${#words[@]}" ]; do
        kv="${words[i]}"
        value="${kv#*=}"
        case "$kv" in
            (cpu=*)     CHART_CPU="$value" ;;
            (cores=*)   CHART_CORES="$value" ;;
            (mem=*)     CHART_MEM="$value" ;;
            (mem_max=*) CHART_MEM_MAX="$value" ;;
            (pids=*)    CHART_PIDS="$value" ;;
            (rx=*)      CHART_RX="$value" ;;
            (tx=*)      CHART_TX="$value" ;;
            (secs=*)    CHART_SECS="$value" ;;
            (tok_in=*)  CHART_TOK_IN="$value" ;;
            (tok_cache=*) CHART_TOK_CACHE="$value" ;;
            (tok_out=*) CHART_TOK_OUT="$value" ;;
            (tok_cost=*) CHART_TOK_COST="$value" ;;
        esac
        i=$(( i + 1 ))
    done

    series_push CPU_SERIES "${CHART_CPU:-0}"
    series_push MEM_SERIES "${CHART_MEM:-0}"
    series_push RX_SERIES "$(chart_positive "${CHART_RX:-0}")"
    series_push TX_SERIES "$(chart_positive "${CHART_TX:-0}")"
    # 'pids' is deliberately NOT pushed to a series: the dashboard shows the
    # current count in the header — a process leak is caught by watching that
    # number grow, a history row bought nothing.
    CHART_SAMPLES=$(( ${CHART_SAMPLES:-0} + 1 ))
    return 0
}

# chart_positive VALUE — a counter reading for a sparkline: a stray non-number
# and a net counter that went backwards both become 0, so neither can poison
# the maximum a series is scaled by.
chart_positive() {
    local v="${1:-0}"
    [[ "$v" =~ $RE_COUNT ]] && { printf '%s' "$v"; return 0; }
    printf '0'
}

# monitor_start_epoch NAME — when the container started, in epoch seconds, or 0
# when neither date dialect can parse the timestamp. The frame then simply
# leaves the uptime out. GNU date parses ISO 8601 with '-d'; BSD date (macOS)
# has no '-d' and wants '-j -f FORMAT' without fractional seconds, so the
# '.123456789' in docker's '…T10:00:00.123456789Z' is stripped for it. '-u'
# matters on both branches: docker stamps STARTED_AT in UTC, and BSD date
# without '-u' reads the parsed time as LOCAL — every uptime then carries the
# timezone offset (a container started two minutes ago reports 'up 01:01:45'
# on a +01:00 laptop).
monitor_start_epoch() {
    local started
    started="$(docker inspect --format '{{.State.StartedAt}}' "$1" 2>/dev/null || echo '')"
    [ -n "$started" ] || { printf '0'; return 0; }
    date -u -d "$started" +%s 2>/dev/null \
        || date -ju -f '%Y-%m-%dT%H:%M:%SZ' "${started%%.*}Z" +%s 2>/dev/null \
        || printf '0'
}

# monitor_uptime EPOCH — 'up HH:MM:SS', or empty when the start time is unknown.
# Past 99 hours the hour field would grow the column and push the header apart,
# so the count switches to days (a container running for days is a fact worth
# reading at a glance, not four digits to parse).
monitor_uptime() {
    local base="${1:-0}" now secs
    [[ "$base" =~ ^[0-9]+$ ]] && [ "$base" -gt 0 ] || return 0
    now="$(date +%s)"; secs=$(( now - base ))
    [ "$secs" -ge 0 ] || secs=0
    if [ "$secs" -ge 359600 ]; then
        printf 'up %dd %02d:%02d' "$(( secs / 86400 ))" "$(( secs % 86400 / 3600 ))" "$(( secs % 3600 / 60 ))"
    else
        printf 'up %02d:%02d:%02d' "$(( secs / 3600 ))" "$(( secs % 3600 / 60 ))" "$(( secs % 60 ))"
    fi
}

# monitor_dashboard NAME INTERVAL — draw one frame. Everything on it comes from
# the state monitor_ingest() maintains; this function calls no docker, reads no
# files and spawns one 'sort' for the destination ranking, so a frame costs one
# write to the terminal. The frame is one write to the alternate screen, so it
# homes the cursor and clears the WHOLE screen first: erasing only below the
# cursor leaves the right-hand tail of any row a previous frame wrote longer —
# a resize, or a frame that shrank by a row — ghosting beside unrelated rows.
# No row may reach the terminal's last column either (see half_w): a wrapped
# row scrolls one line per frame and every later frame draws on a shifted
# screen.
monitor_dashboard() {
    local name="$1" interval="$2"
    local w lw="$CHART_LABEL_WIDTH" rule spark_w half_w bar_w rows
    local frame="" line dest hits=0 cycle_hits=0 shown=0 mem_field mem_pct mem_peak cpu_peak up tok_disp
    local i n rest
    local -a ranked=()

    chart_term_size
    w="$CHART_COLS"
    # The rule is built by appending, not with 'tr': tr is byte-oriented and
    # would turn one '─' into the first byte of a three-byte character.
    rule=""
    while [ "${#rule}" -lt "$(( w - 1 ))" ]; do rule+="$CHART_RULE"; done
    # a full-width row is ' ' + label(lw) + spark(spark_w) = w-1 — the last
    # column stays empty, since anything that touches it wraps and a wrapped
    # frame drifts. sparks no longer shrink while short on samples ('.'
    # placeholders hold the width), so this budget is now always exercised.
    spark_w=$(( w - lw - 2 )); [ "$spark_w" -lt 8 ] && spark_w=8
    # The net row prints 'rx ' + spark + ' tx ' + spark after the label column,
    # so half_w is HALF of what is left AFTER those seven characters, not half
    # of spark_w. At 100 columns the old (spark_w / 2) made the row 106 wide:
    # it wrapped, the explicit \n then scrolled one line per frame, and every
    # next frame drew over a screen shifted by one — the 'duplicated net row'
    # and ghosted tails a wide terminal produced.
    # 'rx ' + ' tx ' cost 7 columns; halves of floor((spark_w-7)/2) keep the
    # full-width net row at 1 + lw + 7 + 2*half_w ≤ w-1 as well
    half_w=$(( (spark_w - 7) / 2 )); [ "$half_w" -lt 4 ] && half_w=4
    bar_w=$(( spark_w / 2 )); [ "$bar_w" -lt 8 ] && bar_w=8
    [ "$bar_w" -gt 24 ] && bar_w=24

    # Fixed overhead of the frame is 11 lines (the tok row under net counts);
    # whatever is left is destination
    # rows, capped so a huge terminal does not get 60 mostly-empty rows.
    rows=$(( CHART_LINES - 11 ))
    [ "$rows" -lt 1 ] && rows=1
    [ "$rows" -gt "$CHART_ROWS" ] && rows="$CHART_ROWS"

    i=0
    n=0
    while [ "$i" -lt "${#DEST_CUR_N[@]}" ]; do
        cycle_hits=$(( cycle_hits + DEST_CUR_N[i] ))
        i=$(( i + 1 ))
    done
    i=0
    while [ "$i" -lt "${#DEST_TOTAL[@]}" ]; do
        hits=$(( hits + DEST_TOTAL[i] ))
        i=$(( i + 1 ))
    done

    up="$(monitor_uptime "${CHART_STARTED_EPOCH:-0}")"
    # The header is the 'right now + worst-case' line: name, uptime, pids and
    # the PEAK cpu/memory of the run — peaks belong next to the uptime (they
    # describe the whole session) rather than trailing their row's gauge.
    # Since the token summary moved to its own row, the items get generous
    # gaps again: name 24, uptime 17, and the tail keeps its own spacing —
    # the whole line still fits an 80-column frame (the 80-col regression
    # test guards that). chart_pad guards the tail as a last resort
    # ('~' beats a wrapped frame).
    mem_peak="$(human_bytes "$(series_max MEM_SERIES)")"
    cpu_peak="$(series_max CPU_SERIES '%.1f')"
    # Token usage across ALL pi sessions the container stores, cumulative,
    # with the input split the way pi's own /usage shows it: uncached prompt
    # tokens and cache reads are different money (once an agent settles into
    # a session the cached side dwarfs the other — one lump figure hid what
    # is actually being paid for). The price rides along only when a provider
    # reported one. '-1' means the image has no jq — an unknown is shown as
    # '?', never as zero.
    if [ -z "${CHART_TOK_IN:-}" ] || [ "${CHART_TOK_IN:-}" = "-1" ]; then
        tok_disp="tok ?"
    elif [ -z "${CHART_TOK_CACHE:-}" ]; then
        # an image from before the split reports the lumped input only —
        # render the old combined form rather than lie about zero cache reads
        tok_disp="tok $(human_count "${CHART_TOK_IN:-0}")/$(human_count "${CHART_TOK_OUT:-0}")"
    else
        # the total leads — 'what has the agent fed the models' is the first
        # question — and the split pi's /usage draws (uncached + cache reads,
        # different money) rides along in parentheses, so nobody does token
        # arithmetic mid-glance
        tok_disp="tok in $(human_count "$(awk -v i="${CHART_TOK_IN:-0}" -v c="${CHART_TOK_CACHE:-0}" 'BEGIN { printf "%d", i + c }')") (in $(human_count "${CHART_TOK_IN:-0}") + cached $(human_count "${CHART_TOK_CACHE:-0}"))  out $(human_count "${CHART_TOK_OUT:-0}")"
    fi
    [ "$(awk -v c="${CHART_TOK_COST:-0}" 'BEGIN { print (c + 0 > 0) ? 1 : 0 }')" = "1" ] &&\
        tok_disp+="  $(printf '$%.2f' "${CHART_TOK_COST}")"
    frame+=" $(chart_pad "$name" 24)$(chart_pad "${up:-up ?}" 17)$(chart_pad "pids ${CHART_PIDS:-?}   peak cpu ${cpu_peak}%/mem ${mem_peak}" "$(( w - 43 ))")"
    frame+=$'\n'"$rule"$'\n'

    # cpu — percent of the container's whole allowance, as in line mode.
    frame+=" $(chart_pad "cpu  ${CHART_CPU:-0}% of ${CHART_CORES:-?} cores" "$lw")$(series_spark CPU_SERIES "$spark_w")"$'\n'

    # mem — a gauge against the limit when there is one (line mode prints
    # 'unlimited' for the same reason; with no limit there is no percentage to
    # gauge, so the column shows the history instead). The run's peak lives in
    # the header now, so this row carries only the live figure.
    if [ "${CHART_MEM_MAX:-max}" = "max" ]; then
        mem_field="mem  $(human_bytes "${CHART_MEM:-0}")/unlimited"
        frame+=" $(chart_pad "$mem_field" "$lw")$(series_spark MEM_SERIES "$spark_w")"$'\n'
    else
        mem_pct="$(awk -v u="${CHART_MEM:-0}" -v l="${CHART_MEM_MAX}" 'BEGIN { printf "%.1f", (l + 0 > 0) ? u * 100 / (l + 0) : 0 }')"
        mem_field="mem  $(human_bytes "${CHART_MEM:-0}")/$(human_bytes "${CHART_MEM_MAX}") (${mem_pct}%)"
        frame+=" $(chart_pad "$mem_field" "$lw")$(bar "$bar_w" "$mem_pct")"$'\n'
    fi

    # net — the newest deltas as numbers, the history as two sparklines.
    frame+=" $(chart_pad "net  ${CHART_DOWN}$(human_bytes "${CHART_RX:-0}") ${CHART_UP}$(human_bytes "${CHART_TX:-0}")" "$lw")"
    frame+="rx $(series_spark RX_SERIES "$half_w") tx $(series_spark TX_SERIES "$half_w")"$'\n'

    # tok — the agent's cumulative LLM token usage on its own row under net:
    # the header is rationed (80 columns showed 't~' where the whole figure
    # should be), and a number nobody has to squeeze is a number that fits.
    frame+=" $(chart_pad "$tok_disp" "$(( w - 2 ))")"$'\n'

    frame+=$'\n'"$(printf 'destinations  this cycle: %d   total: %d   targets: %d' "$cycle_hits" "$hits" "${#DEST_LIST[@]}")"$'\n'

    # Ranking: most RECENTLY called first — a destination's sort key is the
    # last sample it appeared in, so the URLs the container is talking to NOW
    # sit on top and a page the agent stopped looking at sinks, whatever its
    # lifetime count. The accumulated hits are the tie-break (destinations seen
    # in the same sample keep a stable, meaningful order), and every
    # destination ever seen stays listed, so one sort ranks them all.
    i=0
    while [ "$i" -lt "${#DEST_LIST[@]}" ]; do
        ranked+=("$(printf '%s\t%s\t%s' "${DEST_LAST[$i]}" "${DEST_TOTAL[$i]}" "${DEST_LIST[$i]}")")
        i=$(( i + 1 ))
    done
    local tab
    tab=$'\t'
    if [ "${#ranked[@]}" -eq 0 ]; then
        frame+=$'\n'"    (nothing requested since the monitor started)"$'\n'
    else
        while IFS=$'\t' read -r n rest dest && [ "$shown" -lt "$rows" ]; do
            # 'n' is the last-seen sample (the sort key, never printed) and
            # 'rest' the accumulated hits. The hit counts are column-aligned:
            # a ranking you cannot scan vertically is not a ranking.
            frame+=" $(chart_pad "$(printf 'x%-4s %s' "$rest" "$dest")" "$(( w - 2 ))")"$'\n'
            shown=$(( shown + 1 ))
        done < <(printf '%s\n' "${ranked[@]}" | sort -t$'\t' -k1,1nr -k2,2nr)
        [ "${#ranked[@]}" -gt "$rows" ] &&\
            frame+=" $(printf '... %d more destination(s) — the line view shows them all' "$(( ${#ranked[@]} - rows ))")"$'\n'
    fi

    # The hints only fit on a wide frame; a narrow one keeps the one that
    # matters — and chart_pad truncates whatever is left, because a hint that
    # reaches the last column wraps and scrolls the frame one line per draw.
    line="Ctrl-C to stop ${CHART_MID} every ${interval}s"
    [ "$w" -ge 80 ] &&\
        line+=" ${CHART_MID} -i 5 for a calmer chart ${CHART_MID} --no-chart for the line view"
    line="$(chart_pad "$line" "$(( w - 1 ))")"
    # A blank before the hint only when the pane above did not already end in
    # one: 'no destinations' and the '... N more' line already carry their own
    # spacer, and two blank lines here would push the hint off a short screen
    # (which scrolls the frame and smears the next one).
    if [ "${#ranked[@]}" -eq 0 ] || [ "${#ranked[@]}" -le "$rows" ]; then
        frame+="$line"$'\n'
    else
        frame+=$'\n'"$line"$'\n'
    fi

    # Home, CLEAR THE WHOLE SCREEN, then draw — erasing only below the cursor
    # leaves the right-hand tail of every row that a previous frame wrote
    # LONGER (a resize, or simply a frame that shrank by a row): '…line view'
    # ghosting to 'iew' beside an unrelated row was exactly that. The frame is
    # one write to the alternate screen, so a full clear costs no flicker.
    # '\e[K' after the frame trims the cursor's own row — the last row's tail
    # is above the cursor and would otherwise survive a shrink.
    printf '\e[H\e[2J%s\e[K' "$frame"
}

# Entering and leaving the chart. The alternate screen is what keeps the promise
# that a monitor leaves nothing behind: everything it drew is thrown away on
# exit and the terminal comes back exactly as it was, scrollback included.
monitor_screen_on() {
    printf '\e[?1049h\e[?25l'
    CHART_ACTIVE="yes"
}

monitor_screen_off() {
    [ "${CHART_ACTIVE:-no}" = "yes" ] || return 0
    CHART_ACTIVE="no"
    printf '\e[?25h\e[?1049l'
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
    warn_dind_dead "$name"

    local exec_args
    exec_args="$(exec_tty_args)"
    log_cmd "docker exec ${exec_args} ${name} /bin/bash"
    # shellcheck disable=SC2086  # exec_args is intentionally word-split
    exec docker exec ${exec_args} "$name" /bin/bash
}

# Live view of a running agent container: where its network requests go (TLS
# SNI hostnames, plus full URLs for cleartext HTTP) alongside CPU, memory, pids,
# net I/O and the agent's cumulative LLM token usage across all sessions
# (read from pi's session files inside the container). The sampling itself runs inside the container by
# the 'pia-monitor' helper (docker/pia/monitor-inside.sh); this command only resolves the
# container and loops. The monitor writes nothing to disk anywhere — docker exec
# streams the lines straight to this terminal. (The container may still keep a
# destination log for 'pia urls'; this command neither reads nor writes it.)
# Show the nested-container guard log of an agent's throwaway daemon. The
# docker client only ever shows an opaque 'runc did not terminate
# successfully' — the refusal reason lives in the daemon's guard log.
cmd_dindlog() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") dindlog [NAME]"
                echo ""
                echo "Show the nested-container guard log of an agent's throwaway Docker"
                echo "daemon — the refusal reasons behind opaque 'runc did not terminate"
                echo "successfully' errors from nested 'docker run' calls."
                echo ""
                echo "A daemon that self-terminated via the guard's kill switch (opts-volume"
                echo "refusal) shows as not running; recreate it with 'pia restart'."
                exit 0 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift ;;
        esac
    done

    name="$(ensure_prefix "$name")"

    if [ -z "$name" ]; then
        log_error "Please provide a container name."
        log_error "Run '$(basename "$0") dindlog --help' for usage."
        exit 1
    fi

    local dind
    dind="$(dind_name_for "$name")"

    if ! container_exists "$dind"; then
        log_error "No throwaway daemon for '${name}' — was it started with --docker?"
        exit 1
    fi

    log_cmd "docker exec ${dind} cat /var/log/pia-dind-guard.log"
    if container_is_running "$dind"; then
        docker exec "$dind" cat /var/log/pia-dind-guard.log 2>/dev/null \
            || echo "(guard log is empty — no refusals yet)"
    else
        # Exited daemons (e.g. guard kill switch): read the log out of the
        # container layer without starting anything.
        docker cp "${dind}:/var/log/pia-dind-guard.log" - 2>/dev/null | tar -xO 2>/dev/null \
            || echo "(guard log is empty or unreadable — daemon is stopped)"
    fi
}

cmd_monitor() {
    local name="" interval="" mode="cycle" chart=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") monitor [NAME] [OPTIONS]"
                echo ""
                echo "Watch a running agent container: request destinations (TLS SNI hostnames"
                echo "and full cleartext HTTP URLs) plus CPU, memory, pids, net I/O and the"
                echo "agent's LLM token usage across all sessions stored in the container (in/out,"
                echo "and cost when the provider reports one)."
                echo ""
                echo "On a terminal the sample is drawn as a chart dashboard (sparklines for"
                echo "cpu/net history, a gauge for memory, the current pids in the header, a"
                echo "ranked destination pane) that redraws one frame per sample. Piped or"
                echo "redirected, it prints the line view instead: destinations, then one resource"
                echo "line per sample."
                echo ""
                echo "Output goes to the terminal only — no log files are written by the monitor."
                echo "For the full request history since container creation, use 'urls'."
                echo "Press Ctrl-C to stop."
                echo ""
                echo "Options:"
                echo "  -i, --interval <sec>  Seconds per sample cycle (default: 1); with --raw"
                echo "                        it is the length of one capture chunk (default: 5)."
                echo "                        '-i 5' makes for a calmer chart."
                echo "      --raw             Stream destinations continuously, no resource summary"
                echo "      --chart           Draw the dashboard even when stdout is not a terminal"
                echo "                        (the escape codes then go into the pipe too — mostly"
                echo "                        for testing it; charts need cycle mode, not --raw)"
                echo "      --no-chart        The line view, even on a terminal"
                echo ""
                echo "Notes:"
                echo "  * HTTPS hides the URL path — only the hostname (SNI) is visible. Full"
                echo "    URLs are shown for cleartext HTTP (the local proxy servers, etc.)."
                echo "  * NAME may be omitted when exactly one container is running."
                echo "  * Ctrl-C, or the container stopping, also stops the capture inside"
                echo "    the container — nothing is left running behind us."
                echo "  * The dashboard uses the alternate screen, so the terminal is exactly as"
                echo "    it was afterwards; the sparklines live in memory and end with the monitor."
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
            --chart)
                chart="yes" ;;
            --no-chart)
                chart="no" ;;
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

    # Charts need a frame to draw on and something to draw. So: on by default
    # when stdout is a terminal, never with --raw (which streams flows and has no
    # sample), and '--chart' overrides the terminal check — the escape codes then
    # go into the pipe as well, which is mostly useful for the mock test suite
    # (it has no pty), and '--no-chart' keeps the log-friendly line view.
    if [ "$mode" = "raw" ]; then
        if [ "$chart" = "yes" ]; then
            log_error "--chart needs cycle mode: --raw streams destinations and has no sample to chart."
            log_error "Drop --raw, or drop --chart."
            exit 1
        fi
        chart="no"
    elif [ -z "$chart" ]; then
        [ -t 1 ] && chart="yes" || chart="no"
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

    # NOTE: no warn_dind_dead here on purpose — the monitor's docker calls
    # are covered by stateful mock tests (test-commands.sh), and a stranded
    # session surfaces the warning via 'pia exec'/'pia ask' instead.
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
    #
    # Leaving the alternate screen comes first in both, so the closing message
    # lands on the user's own screen and a chart that ended by any path restores
    # the terminal before anything else is printed. monitor_screen_off is a no-op
    # when no chart was drawn, so the line view behaves exactly as before.
    #
    # HUP and PIPE are here for the same reason as INT: without a handler the
    # shell dies from the signal and NO trap runs at all — measured with
    # 'pia monitor --chart | head', which left the terminal on the alternate
    # screen and the sampler alive until its own duration expired. The '|| true'
    # guards matter on exactly those paths: writing to the dead pipe (or the dead
    # terminal) fails, and 'set -e' would otherwise abandon the handler half-way
    # — before the 'exit' that makes it stick.
    trap 'monitor_screen_off || true; printf "\n" 2>/dev/null || true; log_info "Monitor stopped."; exit 0' HUP INT TERM PIPE
    trap "monitor_screen_off; monitor_stop_sampler '$name'" EXIT

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
    elif [ "$chart" = "yes" ]; then
        log_info "Monitoring '${name}' — dashboard, one frame every ${interval}s. Ctrl-C to stop."
    else
        log_info "Monitoring '${name}' — destinations every cycle, resources every ${interval}s. Ctrl-C to stop."
    fi
    if [ "$chart" != "yes" ]; then
        log_info "Legend: 'TLS host (ip)' = HTTPS peer, path stays encrypted · 'HTTP <method> <url>' = cleartext request"
    fi

    # The frame is drawn on the alternate screen, so the banners above stay in
    # the scrollback and the dashboard never leaves a trace when it ends.
    if [ "$chart" = "yes" ]; then
        chart_init
        chart_term_size
        CHART_STARTED_EPOCH="$(monitor_start_epoch "$name")"
        CHART_SAMPLES=0
        monitor_screen_on
    fi

    local rc=0 cycle_out=""
    while container_is_running "$name"; do
        rc=0
        if [ "$chart" = "yes" ]; then
            # The frame replaces this pass's own output, so the exec is captured
            # rather than streamed. stderr is deliberately NOT captured: a broken
            # capture explains itself inside the container, and that message
            # should reach the terminal — the loop exits right afterwards anyway.
            # 'stats' asks the helper for its machine-readable sample line.
            cycle_out="$(docker exec "$name" pia-monitor cycle "$interval" stats)" || rc=$?
            if [ "$rc" -eq 0 ] && ! monitor_ingest "$cycle_out"; then
                # An image built before charts existed prints a normal cycle and
                # no '#stats' line. Draw nothing from it, say so once, drop back
                # to the line view and show what this pass produced.
                chart="no"
                monitor_screen_off
                log_warn "The image used by '${name}' has no chart sample line — using the line view."
                log_warn "Rebuild it (bash scripts/build-docker.sh), then 'pia restart ${name}' for charts."
                printf '%s\n' "$cycle_out"
            elif [ "$rc" -eq 0 ]; then
                monitor_dashboard "$name" "$interval"
            fi
        else
            docker exec "$name" pia-monitor "$sampler_mode" "$sampler_seconds" || rc=$?
        fi
        # A sampler that stopped together with the container is not a broken
        # capture — the loop condition turns that into the plain 'it is gone'
        # ending. Any other non-zero exit already explained itself inside the
        # container (missing CAP_NET_RAW, vanished interface, ...).
        if [ "$rc" -ne 0 ] && container_is_running "$name"; then
            monitor_screen_off
            log_warn "Monitor stopped — the sampler exited with code ${rc}."
            exit 1
        fi
    done

    # Leave the frame before the closing message, otherwise the warning is
    # written to the alternate screen and vanishes with it.
    monitor_screen_off
    log_warn "Container '${name}' is no longer running — monitor ended."
}

# Every destination (TLS SNI hostnames) and cleartext HTTP URL the container
# has called since it was created. The container's entrypoint starts
# 'pia-monitor log' (docker/pia/monitor-inside.sh) on every container start, which
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
    warn_dind_dead "$name"

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
    local ask_docker_mode=""
    local ask_mount=""

    # build_docker_args reads these globals; 'ask' takes no ssh flag and no
    # '-m' except for an ephemeral '--docker-dev' session.
    # --docker IS accepted, but only with the SAFE modes: '--docker-full' is
    # refused below — an unattended session must never hold a host-root-equivalent
    # credential nobody is watching.
    MOUNT_DIR=""
    SSH_FLAG=""
    DOCKER_MODE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: $(basename "$0") ask [NAME] [OPTIONS] [PROMPT...]"
                echo ""
                echo "Run a one-shot non-interactive pi prompt (pi --print)."
                echo ""
                echo "The first argument is the container NAME only if such a"
                echo "container exists; otherwise all arguments form the prompt."
                echo "With NAME the prompt runs inside that container; if it is"
                echo "stopped it is started and stopped again afterwards."
                echo "Without NAME an ephemeral container is created and removed."
                echo ""
                echo "Options:"
                echo "  --docker        Run the prompt against a throwaway sibling"
                echo "                  Docker daemon (same isolation as 'pia run --docker')"
                echo "  --docker-dev    ... and (ephemeral asks only) let that daemon"
                echo "                  see the '-m' workspace, so nested bind mounts work"
                echo "  -m, --mount <dir>  Workspace for an ephemeral '--docker-dev'"
                echo "                  ask; a named container already has its own"
                echo "  --docker-full REFUSED: unattended sessions never get the"
                echo "                  host Docker socket (host-root-equivalent)"
                exit 0 ;;
            --docker)
                ask_docker_mode="dind"
                shift ;;
            --docker=*)
                # The old '--docker=MODE' syntax. Refuse loudly instead of
                # letting it slip into the prompt as harmless-looking text.
                log_error "Option '--docker=…' no longer exists: use '--docker', '--docker-dev' or '--docker-full'."
                exit 1 ;;
            --docker-dev)
                ask_docker_mode="dind-mount"
                shift ;;
            --docker-full)
                log_error "Refusing '--docker-full' for 'pia ask': an unattended"
                log_error "session with the host Docker socket is host-root-equivalent"
                log_error "and nobody is watching it. Use '--docker' (throwaway"
                log_error "daemon), or 'pia run' for an interactive socket session."
                exit 1 ;;
            -m|--mount)
                if [ $# -lt 2 ]; then
                    log_error "Option '$1' requires a value."
                    exit 1
                fi
                ask_mount="$2"
                shift 2 ;;
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

    # --docker for unattended starts: the safe modes only (socket was refused
    # during parsing; anything else fails in validate_docker_mode).
    DOCKER_MODE="$ask_docker_mode"
    validate_docker_mode "$DOCKER_MODE" || exit 1

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

    # 'dind-mount' is allowed for an unattended ask (unlike 'socket'): the
    # session writes only into a directory the user explicitly handed it.
    # An ephemeral ask needs that '-m'; a NAMED container's workspace — and
    # its daemon's bind — were fixed when it was created, so accepting -m
    # there would silently do nothing.
    DIND_WS=""
    if [ "${DOCKER_MODE:-}" = "dind-mount" ]; then
        if [ -n "$ephemeral" ]; then
            MOUNT_DIR="$ask_mount"
            DIND_WS="$(resolve_dind_workspace)" || exit 1
            dind_mount_banner "$name" "$DIND_WS"
        elif [ -n "$ask_mount" ]; then
            log_error "Container '${name}' already has its own workspace — '-m' would be ignored."
            log_error "Recreate it instead: 'pia restart <NAME> -m <dir> --docker-dev'."
            exit 1
        fi
    elif [ -n "$ask_mount" ]; then
        log_error "Option '-m' is only accepted with '--docker-dev'."
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
        log_info "Creating one-shot container '${name}'..."
        if dind_mode_active; then
            start_dind_sibling "$name" "$DIND_WS" || exit 1
        fi
        local docker_args=()
        while IFS= read -r arg; do
            docker_args+=("$arg")
        done < <(build_docker_args "$name")
        log_cmd "docker run -d ${docker_args[*]}"
        if ! docker run -d "${docker_args[@]}" > /dev/null; then
            if dind_mode_active; then remove_dind_siblings "$name"; fi
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

    # A dind-mode agent needs its daemon up before any docker call inside
    # works (and before 'docker start' of a netns-sharing agent at all).
    if dind_mode_active; then
        ensure_dind_siblings_started "$name"
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

    # Same signal guard as the session paths: a closed terminal must not
    # leave an ephemeral container behind or a 'started_by_us' container
    # running. Without a signal, cleanup still runs below after the exec.
    local ask_cleanup="true"
    if [ -n "$ephemeral" ]; then
        ask_cleanup="docker rm -f '$id' > /dev/null 2>&1; remove_dind_siblings '$name'"
    elif [ -n "$started_by_us" ]; then
        ask_cleanup="docker stop '$id' > /dev/null 2>&1; stop_dind_siblings '$name'"
    fi

    warn_dind_dead "$name"
    log_cmd "docker exec ${name} pi --print <prompt>"
    local rc=0
    trap_session_signals "$ask_cleanup"
    docker exec "$id" pi --print "$prompt" || rc=$?
    trap - HUP INT TERM

    if [ -n "$ephemeral" ]; then
        log_cmd "docker rm -f ${name}"
        docker rm -f "$id" > /dev/null 2>&1
        remove_dind_siblings "$name"
    elif [ -n "$started_by_us" ] && container_is_running "$id"; then
        log_cmd "docker stop ${name}"
        docker stop "$id" > /dev/null 2>&1
        stop_dind_siblings "$name"
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

    # Throwaway daemon siblings: a stopped daemon is normally a stray (an
    # agent that ended without teardown, or one that was removed outside
    # pia). Never touch a daemon whose agent is still running — that agent
    # still talks to it ('clean' must never kill a live agent's
    # daemon). Kept containers stay protected like everywhere else.
    local parent
    while IFS=$'\t' read -r id name state created; do
        if [ -z "$id" ]; then continue; fi
        if [[ "$name" == ${KEEP_PREFIX}* ]]; then
            log_info "Skipping protected container '${name}'."
            continue
        fi
        parent="$(docker container inspect -f '{{ index .Config.Labels "pia-parent" }}' "$name" 2>/dev/null)"
        if [ -n "$parent" ] && container_is_running "$parent"; then
            log_info "Skipping daemon '${name}' — its agent '${parent}' is still running."
            continue
        fi
        log_info "Removing stopped daemon container '${name}'..."
        log_cmd "docker rm -f -v ${name}"
        docker rm -f -v "$name" > /dev/null 2>&1 || true
        count=$((count + 1))
    done < <(pia_ps_all --filter "status=exited" --filter "label=pia-role=dind")

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
        warn_dind_dead "$name"
        exit 0
    fi

    log_info "Starting stopped container '${name}'..."
    # If this agent owns a throwaway daemon it must come back first — the
    # agent shares the daemon's netns and cannot start without it.
    ensure_dind_siblings_started "$name"
    local rc=0
    attach_session "$name" || rc=$?
    stop_dind_siblings "$name"
    exit $rc
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
    dindlog)
        cmd_dindlog "$@" ;;
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
