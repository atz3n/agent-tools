#!/bin/bash
# pia-monitor — one sampling cycle of 'pia monitor', run INSIDE the agent
# container (the host-side 'pia monitor' command calls it through docker exec).
#
# 'pia monitor' answers two questions for one interval:
#   1. Where did the traffic go?     TLS ServerNameIndication + cleartext HTTP
#   2. What did the container cost?  CPU, memory, pids, net I/O
#
# The monitor modes write nothing to disk — every line goes to stdout, which
# docker exec streams straight back to the terminal. Only 'log' writes, and
# only to the destination log that backs 'pia urls'.
#
# Usage:
#   pia-monitor cycle [SECONDS] [stats]
#                                 capture for SECONDS, print flows + summary;
#                                 with 'stats' also print one '#stats k=v ...'
#                                 machine-readable line, which is what the
#                                 host-side 'pia monitor' chart draws its
#                                 sparklines from (the human summary stays,
#                                 so a hand-run cycle is unchanged)
#   pia-monitor raw [SECONDS]     stream flows as they happen (no summary);
#                                 without SECONDS it runs until interrupted,
#                                 which is how it is started by hand — stop it
#                                 with Ctrl-C, or from another shell with
#                                 'pkill -f pia-monitor' (the handler below then
#                                 stops the tshark it owns)
#   pia-monitor log               append every request destination to $URL_LOG
#                                 until interrupted — started by the image's
#                                 entrypoint on every container start
#   pia-monitor urls [all]        print the destination log: aggregated by
#                                 destination, or every line with 'all'
#
# 'pia monitor' always passes a duration: it calls this helper once per chunk
# so it can notice a container that disappeared and can stop the capture when
# you press Ctrl-C ('docker exec' without a TTY only signals this shell, never
# the capture it started — see capture()).

# Notes:
#   * HTTPS hides the path: only the hostname (SNI) is visible in the clear.
#     Full URLs are shown for cleartext HTTP (e.g. the local proxy servers).

set -uo pipefail

MODE="${1:-cycle}"
DURATION="${2:-}"
# Third argument of 'cycle': 'stats' asks for the machine-readable sample line
# that backs 'pia monitor' charts. Anything else is a typo, caught below.
STATS="${3:-}"
IFACE="${PIA_MONITOR_IFACE:-any}"
CG="${PIA_MONITOR_CGROUP:-/sys/fs/cgroup}"
# Destination log backing 'pia urls' — written only by the 'log' mode.
URL_LOG="${PIA_URL_LOG:-/var/log/pia-urls.log}"

# tshark fields, pipe separated: time|ip.dst|ipv6.dst|sni|method|host|uri
# Both address families are read because 'ip.dst' is simply empty for v6-only
# peers, which would otherwise print a destination without a peer address.
FILTER='tls.handshake.type == 1 or http.request'
FIELDS='-e frame.time -e ip.dst -e ipv6.dst -e tls.handshake.extensions_server_name -e http.request.method -e http.host -e http.request.uri'

# Set while a capture is running so the signal handler below can stop it.
CAPTURE_PID=""

# Interrupted while reading the capture: kill the capture with us. This works
# precisely because the capture is a background process whose output we read
# (see capture()) — bash runs this trap between lines instead of waiting for
# the capture to finish on its own. The 'wait' is not decoration: PID 1 of this
# image is 'sleep infinity', which never reaps, so a killed tshark we did not
# wait for would sit in the container as a <defunct> entry for the rest of the
# container's life and inflate the 'pids' column of the next monitor. (A helper
# that is itself SIGKILLed never gets to reap: its capture is orphaned, keeps
# running until its own '-a duration:' expires — which is exactly why callers
# never start this with an unbounded duration — and then lingers as a harmless
# <defunct> entry.)
stop_capture() {
    if [ -n "$CAPTURE_PID" ]; then
        kill "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi
    exit 130
}
trap stop_capture INT TERM

if ! command -v tshark > /dev/null 2>&1; then
    echo "[ERROR] tshark is not installed in this image." >&2
    echo "[ERROR] Rebuild it: cd harnesses/pia && ./scripts/build-docker.sh" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# cgroup readers (v2 preferred, v1 fallback) — all container-scoped
# ---------------------------------------------------------------------------

cpu_usec() {
    if [ -r "$CG/cpu.stat" ]; then
        awk '/^usage_usec/ { print $2; exit }' "$CG/cpu.stat"
    elif [ -r "$CG/cpuacct/cpuacct.usage" ]; then
        awk '{ printf "%d", $1 / 1000; exit }' "$CG/cpuacct/cpuacct.usage"
    else
        echo 0
    fi
}

# '<used> <limit>', limit may be 'max'.
#
# 'used' is NOT the raw usage counter: memory.current also counts the page
# cache charged to this cgroup, so after a read-heavy spell (an agent that
# curl'd the internet for an hour) the container 'uses' 12 GiB while its
# processes hold ~1 GiB — the rest is kernel page cache the kernel hands back
# the moment anything needs it. That is not 'in use', so the reclaimable part
# is subtracted, exactly like 'docker stats': usage minus inactive_file on
# v2, usage minus total_inactive_file on v1. (What the agent inside sees via
# /proc/meminfo is yet another basis — HOST-WIDE, since there is no lxcfs —
# which is why its numbers never match the monitor either way.)
mem_bytes() {
    local used limit stat="" key="" cache
    if [ -r "$CG/memory.current" ]; then
        used="$(cat "$CG/memory.current")"
        limit="$(cat "$CG/memory.max" 2>/dev/null || echo max)"
        stat="$CG/memory.stat"
        key="inactive_file"
    elif [ -r "$CG/memory/memory.usage_in_bytes" ]; then
        used="$(cat "$CG/memory/memory.usage_in_bytes")"
        limit="$(cat "$CG/memory/memory.limit_in_bytes" 2>/dev/null || echo max)"
        stat="$CG/memory/memory.stat"
        key="total_inactive_file"
    else
        used=0
        limit=max
    fi
    if [ -n "$stat" ] && [ -r "$stat" ]; then
        cache="$(awk -v k="$key" '$1 == k { print $2; exit }' "$stat")"
        [[ "$cache" =~ ^[0-9]+$ ]] || cache=0
        used=$(( used - cache ))
        [ "$used" -lt 0 ] && used=0
    fi
    # v1 reports 'unlimited' where v2 reports 'max'
    [ "$limit" = "unlimited" ] && limit=max
    # absurd v1 limits (no cap) read as ~2^63 — show them as 'max'
    case "$limit" in (*[0-9]*) [ "$limit" -gt 10995116277760 ] && limit=max ;; esac
    echo "$used $limit"
}

pids_count() {
    if [ -r "$CG/pids.current" ]; then
        cat "$CG/pids.current"
    elif [ -r "$CG/pids/pids.current" ]; then
        cat "$CG/pids/pids.current"
    else
        echo '?'
    fi
}

# '<rx> <tx>' bytes across every interface but the loopback (/proc/net/dev is
# namespaced, so this is the container's own traffic)
net_bytes() {
    awk 'NR > 2 {
        split($1, n, ":"); if (n[1] == "lo") next
        rx += $2; tx += $10
    } END { printf "%d %d", rx + 0, tx + 0 }' /proc/net/dev
}

# Byte counts with a binary suffix. Negative values happen (a net counter that
# went backwards after an interface reset) and keep their sign, so a summary
# never reads '--12.0KiB'.
human() {
    awk -v b="$1" 'BEGIN {
        if (b < 0) { printf "-"; b = -b }
        if (b >= 1073741824)   printf "%.1fGiB", b / 1073741824
        else if (b >= 1048576) printf "%.1fMiB", b / 1048576
        else if (b >= 1024)    printf "%.1fKiB", b / 1024
        else                   printf "%dB", b
    }'
}

# Token counts with a decimal k/M suffix — 262.1k reads better in a header
# than 262144, and tokens are never binary-sized.
human_tok() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1000000) printf "%.1fM", n / 1000000
        else if (n >= 1000) printf "%.1fk", n / 1000
        else printf "%d", n
    }'
}

# ---------------------------------------------------------------------------
# token usage — the other half of 'what is this agent costing'
#
# pi writes every assistant message's usage into its session JSONLs under
# ~/.pi/agent/sessions; tok_usage prints '<in> <cache> <out> <cost>' CUMULATED
# ACROSS ALL SESSIONS the container stores — the running one plus every
# session it has ever had. Input is split the way pi's own /usage shows it:
# uncached prompt tokens ('in') and cache reads ('cache') are different money,
# and after an agent has settled into a session the cached side dwarfs the
# other — lumping them together hid what is actually being paid for.
# They live on the container's own filesystem, so the total survives
# stop/start and 'pia resume' and ends with 'pia remove' — the ledger of this
# container's agent, which is the question the monitor answers. Cost is
# whatever the providers reported (0 for local models). Files are summed one
# jq call each: the newest line of a LIVE session can be half-written, and a
# per-file parse error must cost that file's tail, never the whole ledger.
# Without jq (a stripped image) the fields report -1 and the host shows
# 'tok ?'.
tok_usage() {
    local dir="${PIA_PI_SESSIONS:-$HOME/.pi/agent/sessions}" f
    command -v jq >/dev/null 2>&1 || { echo "-1 -1 -1 -1"; return 0; }
    [ -d "$dir" ] || { echo "0 0 0 0"; return 0; }
    find "$dir" -name '*.jsonl' -type f -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
        jq -r 'select(type == "object") | (.message.usage // empty)
               | [(.input // 0), (.cacheRead // 0), (.output // 0), (.cost.total // 0)] | @tsv' \
            "$f" 2>/dev/null
    done |
    awk '{ i += $1; ca += $2; o += $3; c += $4 } END { printf "%d %d %d %.6g\n", i, ca, o, c }'
}

# ---------------------------------------------------------------------------
# flow formatting: turn tshark's 'time|ip|ip6|sni|method|host|uri' records into one
# readable line per destination.
#
# Deliberately plain bash instead of awk: mawk fills its input buffer from a pipe
# and only hands lines over when the buffer is full (or at EOF), which would keep
# a streaming 'pia monitor --raw' silent for minutes. 'read' returns per line.
#
#   flows 0  cycle mode — collapse runs of the same destination into one line
#                        with an xN count (a chatty API polls; 200 identical
#                        lines read worse than one)
#   flows 1  raw mode    — print every hit immediately, nothing held back
# ---------------------------------------------------------------------------

# Prints the accumulated run of identical destinations held in the globals set by
# flows() (bash's dynamic scoping lets this helper see its caller's locals).
_flush_run() {
    [ -n "$prev" ] || return 0
    if [ "$count" -gt 1 ]; then
        printf '%s  %s   x%d\n' "$first" "$prev" "$count"
    else
        printf '%s  %s\n' "$first" "$prev"
    fi
    prev=""; count=0
}

# Matched as a variable operand, not inline: bash 3.2 (macOS' /bin/bash,
# should this helper ever be run on a host) aborts on unquoted parentheses
# inside '[[ =~ ]]'.
RE_HMS='([0-9][0-9]:[0-9][0-9]:[0-9][0-9])'

flows() {
    local stream="${1:-0}" t ip ip6 sni method host uri peer target what prev="" first="" count=0

    while IFS='|' read -r t ip ip6 sni method host uri; do
        peer="$ip"; [ -n "$peer" ] || peer="$ip6"
        # the time field looks like: Nov  3, 2026 17:21:32.415311341 UTC
        if [[ "$t" =~ $RE_HMS ]]; then
            t="${BASH_REMATCH[1]}"
        else
            t="--:--:--"
        fi

        # a TLS handshake without SNI (IP literal, or TLS 1.3 ECH) — show the peer
        if [ -n "$sni" ]; then
            target="$sni ($peer)"
        else
            target="$peer"
        fi

        if [ -n "$method" ]; then
            what="HTTP  $method $host$uri"
        else
            what="TLS   $target"
        fi

        if [ "$stream" = "1" ]; then
            printf '%s  %s\n' "$t" "$what"
            continue
        fi

        if [ "$what" = "$prev" ]; then
            count=$(( count + 1 ))
            continue
        fi

        _flush_run
        prev="$what"; first="$t"; count=1
    done

    [ "$stream" = "1" ] || _flush_run
}

# capture SECONDS STREAM — capture for SECONDS (empty: until interrupted) and
# hand the records to flows(). STREAM: 0 = collapse repeats, 1 = print as they
# come. Returns the capture's exit status, so a broken capture is reportable.
#
# The capture runs as a process substitution on fd 3 rather than as the left
# side of a pipeline on purpose:
#   * in a pipeline bash waits for its children and defers traps until they
#     are gone, so Ctrl-C could never stop a running capture; reading the fd
#     instead blocks inside 'read', where bash does run the trap at once;
#   * '$!' is then the capture's own pid, which is what the trap kills;
#   * and 'wait' still hands back the capture's exit status, which a pipeline
#     would only reveal through pipefail.
capture() {
    local duration="${1:-}" stream="${2:-0}"
    local rc=0

    # -Q quiet, -i interface, -n no DNS lookup, -l flush per packet,
    # -t a wall-clock timestamps, -a duration stop after N seconds.
    # tshark's own warnings go to /dev/null so a cycle stays readable; a real
    # failure is reported by report_capture_failure() with the original message.
    local args=(-Q -i "$IFACE" -n -l -t a -Y "$FILTER" -T fields -E separator='|' $FIELDS)
    [ -n "$duration" ] && args+=(-a "duration:$duration")

    exec 3< <(tshark "${args[@]}" 2>/dev/null)
    CAPTURE_PID=$!

    flows "$stream" <&3
    exec 3<&-

    wait "$CAPTURE_PID" || rc=$?
    CAPTURE_PID=""
    return "$rc"
}

# Exit codes that mean "the capture was stopped", not "the capture is broken":
# 130 SIGINT (Ctrl-C), 141 SIGPIPE (reader went away), 143 SIGTERM.
is_normal_stop() {
    case "$1" in (0 | 130 | 141 | 143) return 0 ;; *) return 1 ;; esac
}

# Re-run the failing capture for one second with stderr kept, so the user sees
# tshark's actual complaint ("Can't open device ...") instead of a bare exit code.
# The two warnings dumpcap always prints are filtered out.
report_capture_failure() {
    local rc="$1" diag
    diag="$(tshark -Q -i "$IFACE" -n -a duration:1 -Y "$FILTER" -T fields -e frame.number 2>&1 >/dev/null |\
        grep -vE '^ *$|Running as user|cap_set_proc|^tshark: *$' | tr '\n' ' ' | sed 's/  */ /g')"
    printf '[ERROR] Capture on %s failed (tshark exit %s).\n' "$IFACE" "$rc" >&2
    [ -n "$diag" ] && printf '[ERROR] tshark: %s\n' "$diag" >&2
    printf '[ERROR] Usual causes: the interface is gone (list them with tshark -D), or\n' \
           '[ERROR] CAP_NET_RAW was dropped — plain Docker always grants it.\n' >&2
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

run_raw() {
    # Without a duration this is a hand-started capture, so say what is
    # happening. 'pia monitor' passes chunk lengths and prints its own banner.
    if [ -z "$DURATION" ]; then
        echo "[INFO] Streaming destinations on '${IFACE}' — Ctrl-C to stop."
    fi

    local rc=0
    capture "$DURATION" 1 || rc=$?
    is_normal_stop "$rc" && return 0
    report_capture_failure "$rc"
    exit 2
}

# One interval: sample the counters, capture for DURATION, sample again, then
# print the flows and the resource line. Reading the counters around the capture
# is what turns cumulative cgroup counters into a per-interval CPU/net figure.
run_cycle() {
    [ -n "$DURATION" ] || DURATION=3

    local cores cpu1 cpu2 net1 net2 cap_rc=0
    cores="$(nproc 2>/dev/null || echo 1)"
    cpu1="$(cpu_usec)"
    net1=($(net_bytes))

    capture "$DURATION" || cap_rc=$?

    cpu2="$(cpu_usec)"
    net2=($(net_bytes))

    local mem used limit mem_pct mem_field cpu_pct pids
    local tok_in tok_cache tok_out tok_cost tok_field
    mem="$(mem_bytes)"
    pids="$(pids_count)"
    read -r tok_in tok_cache tok_out tok_cost <<< "$(tok_usage)"

    cpu_pct="$(awk -v a="$cpu1" -v b="$cpu2" -v d="$DURATION" -v n="$cores" \
        'BEGIN { t = d * n * 1000000; printf "%.1f", (t > 0) ? (b - a) * 100 / t : 0 }')"

    # With no limit set there is no percentage to show, so the field stays
    # 'used/unlimited' rather than trailing a meaningless '(?%)'.
    used="${mem%% *}"
    limit="${mem##* }"
    if [ "$limit" = "max" ]; then
        mem_field="$(human "$used")/unlimited"
    else
        mem_pct="$(awk -v u="$used" -v l="$limit" 'BEGIN { printf "%.1f", (l > 0) ? u * 100 / l : 0 }')"
        mem_field="$(human "$used")/$(human "$limit") (${mem_pct}%)"
    fi

    # A broken capture must not masquerade as an idle container: say so before
    # anything else, and tell the host loop (which stops on a non-zero exit)
    # instead of printing empty cycles.
    if ! is_normal_stop "$cap_rc"; then
        report_capture_failure "$cap_rc"
        exit 2
    fi

    if [ "$tok_in" = "-1" ]; then
        tok_field="tok ?"
    else
        tok_field="tok in $(human_tok "$(awk -v i="$tok_in" -v c="$tok_cache" 'BEGIN { printf "%d", i + c }')") (in $(human_tok "$tok_in") + cached $(human_tok "$tok_cache")) out $(human_tok "$tok_out")"
        # the price only when a provider actually reported one
        tok_field="$tok_field$(awk -v c="$tok_cost" 'BEGIN { if (c + 0 > 0) printf " $%.2f", c + 0 }')"
    fi

    printf -- '-- cpu %s%% of %s core(s)  mem %s  pids %s  net -%s +%s  %s  [%ss]\n' \
        "$cpu_pct" "$cores" "$mem_field" "$pids" \
        "$(human "$(( net2[0] - net1[0] ))")" \
        "$(human "$(( net2[1] - net1[1] ))")" \
        "$tok_field" "$DURATION"

    # The same sample in machine-readable form, for 'pia monitor' charts. Raw
    # byte counts and plain numbers on purpose: the host does its own scaling,
    # so nothing here has to be parsed back out of a human string. 'pids' may
    # be '?' (no pids cgroup), 'mem_max' may be 'max', and the tok_* fields are
    # cumulative across ALL sessions the container stores; the host handles
    # all of them.
    if [ "$STATS" = "stats" ]; then
        printf '#stats cpu=%s cores=%s mem=%s mem_max=%s pids=%s rx=%s tx=%s secs=%s tok_in=%s tok_cache=%s tok_out=%s tok_cost=%s\n' \
            "$cpu_pct" "$cores" "$used" "$limit" "$pids" \
            "$(( net2[0] - net1[0] ))" "$(( net2[1] - net1[1] ))" "$DURATION" \
            "$tok_in" "$tok_cache" "$tok_out" "$tok_cost"
    fi
}

# ---------------------------------------------------------------------------
# destination log — the persistent history behind 'pia urls'
#
# The image's entrypoint starts 'pia-monitor log' on every container start,
# so the log covers the whole life of the container and survives stop/start
# cycles (it is on the container's filesystem); only 'pia remove' loses it.
#
# Unlike the monitor captures this one is deliberately unbounded: there is no
# host-side reader that could notice a vanished container, because the
# container itself runs us. If it is ever SIGKILLed its tshark lingers until
# the container stops — and the next container start brings the logger back.
# ---------------------------------------------------------------------------

# Clearing threshold for the log, checked at startup: roughly 80k request
# lines. Rotating mid-run would race the appending tshark for no real gain.
URL_LOG_MAX_BYTES=8388608

# Same fields as the monitor capture, but with 'frame.time_epoch': in tshark
# 4.0 (this image) '-T fields -e frame.time' ignores '-t' entirely and always
# prints wall-clock text, while frame.time_epoch is always epoch seconds —
# what run_urls() feeds to 'date -d @...'.
URL_FIELDS='-e frame.time_epoch -e ip.dst -e ipv6.dst -e tls.handshake.extensions_server_name -e http.request.method -e http.host -e http.request.uri'

run_log() {
    local other size

    # One logger per container: the entrypoint runs on every start, and a
    # hand-started 'pia-monitor log' must not double-log with it.
    #
    # Match by process name (pgrep -x), not with 'pgrep -f "pia-monitor log"':
    # a -f pattern also matches the forked subshell that runs pgrep itself
    # (its inherited cmdline is '.../pia-monitor log'), so the guard would
    # always see a phantom second logger and never start one. The kernel sets
    # comm to the script name on a shebang exec, so -x pia-monitor finds every
    # live monitor instance; our own pid is skipped, and the last cmdline
    # argument tells log mode from cycle/raw/urls. A zombie (empty cmdline,
    # never reaped because PID 1 is 'sleep infinity') is dead, not live, and
    # does not block a new logger.
    for other in $(pgrep -x pia-monitor 2>/dev/null); do
        [ "$other" = "$$" ] && continue
        # 'cat' (not a shell redirect) so a pid that vanishes right after
        # pgrep ran — a monitor that just exited — fails silently.
        [ "$(cat "/proc/$other/cmdline" 2>/dev/null | tr '\0' '\n' | tail -n1)" = "log" ] || continue
        echo "[INFO] Another 'pia-monitor log' is already running — nothing to do." >&2
        return 0
    done

    if [ -f "$URL_LOG" ]; then
        size="$(wc -c < "$URL_LOG" 2>/dev/null || echo 0)"
        [ "${size:-0}" -gt "$URL_LOG_MAX_BYTES" ] && : > "$URL_LOG"
    fi
    printf '# logger started %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$URL_LOG"

    # Restart loop: an interface flap or a tshark that dies must not end the
    # history early. bash stays as tshark's parent and reaps it, so no
    # <defunct> entries pile up (PID 1 of this image never reaps).
    # '-l' flushes per packet, so 'pia urls' sees fresh entries immediately
    # instead of whenever tshark's output buffer happens to fill.
    while :; do
        tshark -Q -i "$IFACE" -n -l -Y "$FILTER" -T fields -E separator='|' $URL_FIELDS >> "$URL_LOG" 2>/dev/null
        sleep 1
    done
}

# Print the destination log for 'pia urls'. Default: one line per destination
# with first-seen time and hit count, in order of first appearance. 'all':
# every logged request line, raw, in order. Comment lines ('# logger started
# ...') are skipped. The record format is the tshark field list above with
# '|' separators and an epoch-seconds timestamp.
run_urls() {
    local mode="${1:-summary}"

    if [ ! -r "$URL_LOG" ]; then
        echo "[ERROR] No destination log at '${URL_LOG}'." >&2
        echo "[ERROR] The container was created from an image whose entrypoint does not" >&2
        echo "[ERROR] run the URL logger. Rebuild the image (bash scripts/build-docker.sh)," >&2
        echo "[ERROR] then recreate the container with 'pia restart <NAME>'." >&2
        exit 2
    fi

    local t ip ip6 sni method host uri peer what total=0
    local -A count=() first=()
    local -a order=()

    while IFS='|' read -r t ip ip6 sni method host uri; do
        case "$t" in ('' | \#*) continue ;; esac
        total=$(( total + 1 ))
        if [ "$mode" = "all" ]; then
            printf '%s\n' "$t|$ip|$ip6|$sni|$method|$host|$uri"
            continue
        fi

        peer="$ip"; [ -n "$peer" ] || peer="$ip6"
        if [ -n "$method" ]; then
            what="HTTP  $method $host$uri"
        elif [ -n "$sni" ]; then
            what="TLS   $sni ($peer)"
        else
            what="TLS   $peer"
        fi

        if [ -n "${count[$what]+x}" ]; then
            count[$what]=$(( count[$what] + 1 ))
        else
            count[$what]=1
            first[$what]="$t"
            order+=("$what")
        fi
    done < "$URL_LOG"

    if [ "$mode" = "all" ]; then
        printf '[INFO] %d logged request(s) in %s\n' "$total" "$URL_LOG"
        return 0
    fi

    if [ "${#order[@]}" -eq 0 ]; then
        echo "[INFO] Nothing has been requested since the container was created."
        return 0
    fi

    printf '[INFO] %d request(s) to %d destination(s) since the container was created (%s):\n' \
        "$total" "${#order[@]}" "$URL_LOG"
    local dest shown
    for dest in "${order[@]}"; do
        # epoch (maybe with fractional seconds) -> 'YYYY-MM-DD HH:MM:SS UTC'
        shown="$(date -u -d "@${first[$dest]%%.*}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${first[$dest]}")"
        printf '%s  x%-4d %s\n' "$shown" "${count[$dest]}" "$dest"
    done
}

# A duration is always a whole number of seconds; 'pia monitor' validates its
# own arguments, so anything else here means a hand-typed call. Only the
# monitor modes take one. The only accepted third argument is 'stats', and only
# for 'cycle' — 'raw' streams flows and has no sample to describe.
case "$MODE" in
    (cycle | raw)
        case "$DURATION" in
            (*[!0-9]*)
                echo "[ERROR] Duration must be a whole number of seconds (got '${DURATION}')." >&2
                exit 2
                ;;
        esac
        ;;
esac

if [ -n "$STATS" ] && { [ "$MODE" != "cycle" ] || [ "$STATS" != "stats" ]; }; then
    echo "[ERROR] Unknown option for 'pia-monitor cycle': '${STATS}' (expected 'stats')." >&2
    exit 2
fi

case "$MODE" in
    raw)   run_raw ;;
    cycle) run_cycle ;;
    log)   run_log ;;
    urls)  run_urls "${2:-}" ;;
    *)
        echo "[ERROR] Unknown mode: $MODE (expected 'cycle', 'raw', 'log' or 'urls')" >&2
        exit 2
        ;;
esac
