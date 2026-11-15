#!/bin/sh
# pia-dind-guard GUARD_VERSION=1
#
# Nested-container policy guard for pia's throwaway Docker daemons.
#
# It runs AS the daemon's 'runc' (the real binary is '$0.real'), so every
# nested container create/exec passes through it — including
# '--runtime=runc'. It reads the OCI config.json from the bundle and refuses
# privileged/capped/device/host-namespace/out-of-policy-bind workloads; the
# policy table lives in docs/docker.md.
#
# Policy summary:
#  * capabilities are an ALLOW-list: only Docker's default cap set is
#    permitted. A deny-list is unsafe — an unconfined container with BPF +
#    PERFMON is an arbitrary kernel-memory read primitive, and new capability
#    names must be refused by construction.
#  * the seccomp section must be present and deny-by-default
#    (SCMP_ACT_ERRNO/KILL*). An omitted section (seccomp=unconfined) or a
#    default-ALLOW profile would let that primitive through.
#  * exec is policed, not passed through: 'docker exec --privileged' injects
#    every cap and 'runc exec -f' replaces the process config wholesale, so
#    exec CAN exceed create-time bounds — both channels are checked.
#  * bind sources are checked as written and as the kernel resolves them, then
#    kernel-pinned (see below); daemon plumbing files are accepted only in
#    docker's own shape (own container id, canonical destination).
#  * refusals write the runtime log in runc's own logrus format
#    ({"level","msg","time"}) — the shape containerd parses and surfaces to
#    the client; JSON is built by jq so a reason with quotes or backslashes
#    stays parsable.
#
# Baking, with verification: this file ships in the pia-dind image (built
# from this folder, FROM digest-pinned docker:29-dind) and the image's
# entrypoint installs it as runc at container start. The GUARD_VERSION
# marker on line 2 IS the policy version — the image tag is derived from it
# and 'pia' verifies a running daemon carries it.
#
# Parsing is jq's job: every decision reads the spec through jq queries, not
# text patterns — immune to whitespace/key-order drift in future containerd
# serializers. If jq is missing or config.json unparsable the guard REFUSES
# (fail-closed); there is no fallback text parser. The kernel-side checks
# (pin mounts, /proc/self/mountinfo verification) deliberately do NOT use
# JSON — they observe what the kernel actually mounted, which no parser can.
#
# Constraints: POSIX sh + busybox applets + jq only (the daemon is Alpine;
# no bash, no coreutils, no python). Keep 'sh -n' clean; the test suite
# lint-checks this file directly (tests/test-docker-modes.sh).
#
REAL="${0}.real"
pins=""
CONF=/usr/local/etc/pia-dind-guard.conf
LOGF=/var/log/pia-dind-guard.log
JQ=/usr/bin/jq
# die() writes the runtime log so the refusal reason reaches the client.
# Containerd ≥2.x (shim v2) parses that file in runc's own logrus format
# ({"level":"error","msg":...,"time":...}) and surfaces 'msg' in the docker
# error; the {"log","args","err"} shape is NOT read. JSON is built by jq so a
# reason with quotes or backslashes stays parsable. Without a log channel the
# client sees only 'runc did not terminate successfully'.
die() {
    release_pins    # first: later writes may SIGPIPE; pins must never outlive us
    echo "pia-dind-guard: REFUSED: $1" | tee -a "$LOGF" >&2
    echo "$(date -u +%FT%TZ) pia-dind-guard: CONTEXT sub='$sub' logarg='${logarg:-<none>}' bundle='${bundle:-<none>}'" >> "$LOGF"
    if [ -x "$JQ" ]; then
        runclog=$("$JQ" -n --arg msg "pia-dind-guard: REFUSED: $1" --arg t "$(date -u +%FT%TZ)" \
            '{level:"error",msg:$msg,time:$t}' 2>/dev/null) || runclog=""
        if [ -n "$runclog" ]; then
            [ -n "$logarg" ] && printf '%s\n' "$runclog" > "$logarg" 2>/dev/null
            if [ -n "$bundle" ] && [ -d "$bundle" ]; then
                printf '%s\n' "$runclog" > "$bundle/log.json" 2>/dev/null
            fi
        fi
    fi
    exit 1
}
# Guard against pin leaks on every refusal path (pins is '' until created).
release_pins() {
    [ -n "${pins:-}" ] || return 0
    for p in $pins; do
        umount -l "$p" 2>/dev/null || umount "$p" 2>/dev/null
        rmdir "$p" 2>/dev/null || rm -f "$p" 2>/dev/null
    done
    pins=""
}
[ -x "$REAL" ] || { echo "pia-dind-guard: real runc missing at $REAL" >&2; exit 1; }
[ -x "$JQ" ] || die "jq payload missing — the daemon image is not the built pia-dind image"

sub="" bundle="" logarg="" prev=""
for a in "$@"; do
    [ "$prev" = "--bundle" ] && bundle="$a"
    [ "$prev" = "--log" ] && logarg="$a"
    case "$a" in create|exec) sub="$a" ;; esac
    prev="$a"
done
case "$sub" in
    create|exec) ;;
    *) exec "$REAL" "$@" ;;
esac

# Capabilities: an ALLOW-list. A deny-list is unsafe — BPF, PERFMON,
# CHECKPOINT_RESTORE, LINUX_IMMUTABLE (what the entrypoint's 'chattr +i'
# tamper-proofing assumes unreachable), NET_ADMIN, ... would all slip past.
# Anything outside Docker's own default set is refused, so future capability
# names are refused by construction. Shared by the create path and the
# exec '-f' process config.
caps_check() {
    for c in $1; do
        [ -n "$c" ] || continue
        case " CHOWN DAC_OVERRIDE FOWNER FSETID KILL SETGID SETUID SETPCAP NET_BIND_SERVICE NET_RAW SYS_CHROOT MKNOD AUDIT_WRITE SETFCAP " in
            *" $c "*) ;;
            *) die "CAP_$c requested ($2 — only Docker's default cap allow-list is permitted)" ;;
        esac
    done
}

if [ "$sub" = "exec" ]; then
    # Exec CAN exceed create-time bounds: the exec API has a Privileged field
    # ('docker exec --privileged' → runc injects EVERY capability at exec
    # time) and 'runc exec -f FILE' replaces the process config wholesale,
    # caps included. Both channels are policed; a normal exec carries the
    # container's create-time (already allow-listed) caps and passes.
    eprev="" execproc=""
    for a in "$@"; do
        [ "$a" = "--privileged" ] && die "exec --privileged (exec must inherit create-time bounds)"
        case "$eprev" in -f|--process) execproc="$a" ;; esac
        eprev="$a"
    done
    if [ -n "$execproc" ] && [ -f "$execproc" ]; then
        "$JQ" -e . "$execproc" > /dev/null 2>&1 || die "exec process config unparsable by jq"
        caps_check "$("$JQ" -r '(.capabilities // .process.capabilities // {}) | (.bounding,.effective,.inheritable,.permitted,.ambient) | .[]?' "$execproc" | sed 's/^CAP_//')" "exec -f"
    fi
    # Exec without a bundle has nothing else to inspect; with a bundle the
    # container's own (already-policed) create spec falls through below.
    if [ -z "$bundle" ]; then
        exec "$REAL" "$@"
    fi
fi

# Container id (create only): the positional argument after 'create', with
# the known value-taking create flags skipped. It tells docker's OWN
# per-container plumbing binds apart from an agent grafting someone else's.
cid=""
if [ "$sub" = "create" ]; then
    seen_create="" skip_val=""
    for a in "$@"; do
        if [ -n "$seen_create" ]; then
            if [ -n "$skip_val" ]; then skip_val=""; continue; fi
            case "$a" in
                --bundle|--log|--pid-file|--console-socket|--preserve-fds) skip_val=1 ;;
                -*) ;;
                *) cid="$a"; break ;;
            esac
        fi
        [ "$a" = "create" ] && seen_create=1
    done
fi

[ -n "$bundle" ] || die "$sub without --bundle"
cfg="$bundle/config.json"
[ -f "$cfg" ] || die "$sub bundle without config.json"
"$JQ" -e . "$cfg" > /dev/null 2>&1 || die "config.json unreadable by jq"

# Privilege and capabilities. '.linux.privileged' is the direct answer to
# --privileged; --cap-add lands in the capability sets, which the cap
# allow-list checks against Docker's default set (a privileged container
# also lists every CAP_* in bounding/permitted, so it is caught twice — the
# explicit check keeps the refusal message honest).
if [ "$("$JQ" -r 'if .linux.privileged == true then "yes" else "no" end' "$cfg")" = "yes" ]; then
    die "--privileged requested"
fi
caps_check "$("$JQ" -r '.process.capabilities | (.bounding,.effective,.inheritable,.permitted,.ambient) | .[]?' "$cfg" | sed 's/^CAP_//')" "create"

# Seccomp: the kernel-read primitive needs BOTH odd caps AND an unconfined
# filter — Docker's default profile blocks bpf()/perf_event_open().
# '--security-opt seccomp=unconfined' makes moby OMIT the seccomp section
# entirely; a custom profile lands inline. Only deny-by-default profiles
# (SCMP_ACT_ERRNO/KILL*) are accepted — a default-ALLOW profile with a
# deny-list is one forgotten syscall from the same primitive, and an
# arbitrary inline profile cannot be audited here.
if [ "$sub" = "create" ]; then
    secc=$("$JQ" -r 'if .linux.seccomp == null then "absent"
        elif ((.linux.seccomp.profile // "") == "unconfined") then "unconfined"
        elif ((.linux.seccomp.defaultAction // "") | test("^SCMP_ACT_(ERRNO|KILL|KILL_THREAD|KILL_PROCESS)$")) then "ok"
        else "weak" end' "$cfg")
    case "$secc" in
        ok) ;;
        absent) die "seccomp section omitted (--security-opt seccomp=unconfined)" ;;
        unconfined) die "seccomp profile 'unconfined'" ;;
        *) die "seccomp profile is not deny-by-default (defaultAction must be SCMP_ACT_ERRNO/KILL*)" ;;
    esac
    # AppArmor: no custom profile is inspectable here, so only the explicit
    # 'unconfined' marker is refused (Alpine daemons usually carry none).
    [ "$("$JQ" -r '.linux.apparmorProfile // ""' "$cfg")" = "unconfined" ] && die "apparmor profile 'unconfined'"
fi

# Device rules via jq. Block devices are NEVER legitimate — a default spec
# has zero
# '"type":"b"' rules; only --device or a privileged wildcard produce them.
# Allowed CHAR rules are exactly Docker's default set, matched by
# major:minor; anything else (--device /dev/mem = 1:1, an 'allow'-typed
# wildcard = -1:-1, or a rule missing major/minor → 'null:null') refuses.
blk=$("$JQ" -r '.linux.resources.devices[]? | select(.type=="b") | .path // "wildcard"' "$cfg")
[ -n "$blk" ] && die "block device (--device or privileged wildcard): $blk"
for mm in $("$JQ" -r '.linux.resources.devices[]? | select(.allow==true) | "\(.major):\(.minor)"' "$cfg"); do
    case "$mm" in
        1:3|1:5|1:7|1:8|1:9|5:0|5:1) ;;
        *) die "device rule outside the default set: $mm" ;;
    esac
done

if [ "$sub" = "create" ]; then
    # Namespace joins. Two distinct shapes, both refused:
    #  * ANY namespace carrying a 'path' — fresh namespaces are CREATED
    #    (no path); a path means joining an existing one (=host on older
    #    daemons, or container:X). Every path is refused, not just known
    #    /proc/N/ns and netns prefixes.
    #  * a MISSING entry — docker's =host modes simply omit the namespace
    #    instead of creating one (--pid=host writes no path to catch).
    # cgroup/time are deliberately not required: docker's default cgroupns
    # is host on cgroup-v1 hosts, and requiring it would break them.
    nspath=$("$JQ" -r '.linux.namespaces[]? | select(.path != null) | .path' "$cfg" | head -1)
    [ -n "$nspath" ] && die "external namespace join via $nspath (--pid/--net/--ipc/--uts=host or container:)"
    nstypes=$("$JQ" -r '.linux.namespaces[]? | .type' "$cfg")
    for t in mount network uts pid ipc; do
        case "
$nstypes
" in *"
$t
"*) ;; *) die "missing $t namespace (=host join, refused)" ;;
        esac
    done
fi

# Local-driver volume options: a volume created with
# 'docker volume create -o device=… -o type=…' is mounted by the DAEMON
# itself (any device or filesystem, e.g. type=none,o=rbind,device=/ or a raw
# VM disk partition); the container spec only shows a plausible
# /var/lib/docker/volumes/<name>/_data source, so bind policing cannot see
# it. The local driver records its options in opts.json next to _data — a
# plain (anonymous or option-less) volume has none. Such a mount also cannot
# be rolled back safely: rbind copies /proc etc. as peer-group members, and
# docker's teardown unmount propagates onto the daemon's own /proc, killing
# the daemon as a zombie. Kill dockerd BEFORE refusing: no rollback unmount
# ever runs, the daemon container exits cleanly and 'pia' recreates it.
for v in $("$JQ" -r '.mounts[]?.source // empty
    | select(startswith("/var/lib/docker/volumes/"))
    | ltrimstr("/var/lib/docker/volumes/") | split("/")[0]' "$cfg" | sort -u); do
    if [ -e "/var/lib/docker/volumes/$v/opts.json" ]; then
        echo "$(date -u +%FT%TZ) pia-dind-guard: KILL volume '$v' carries local-driver options; killing dockerd" >> "$LOGF"
        pkill -9 dockerd 2>/dev/null
        die "volume '$v' carries local-driver options (daemon-side mount)"
    fi
done

# Per-container plumbing files (/etc/hosts, /etc/hostname, /etc/resolv.conf)
# are bind-mounted rw into every container by docker — a nested container
# writing its OWN plumbing file writes a daemon file, which is docker's own
# semantics and stays. What must be impossible is an AGENT-requested graft:
# another container's plumbing file (persistent DNS-pinning of a sibling's
# workload) or a plumbing file at a non-canonical destination. Only docker's
# own shape passes: source under THIS container's id, destination exactly
# /etc/<name>. The bare daemon /etc/{hosts,hostname,resolv.conf} are not
# allowed sources at all (a rw bind of the daemon's own /etc/hosts into a
# nested container is a persistent write). Docker-generated paths contain no
# whitespace, so the word-split loop below is safe.
if [ "$sub" = "create" ]; then
    for pd in $("$JQ" -r '.mounts[]? | select(.source // "" | test("^/var/lib/docker/containers/[^/]+/(hosts|hostname|resolv\\.conf)$")) | .source + "=" + (.destination // "")' "$cfg"); do
        psrc=${pd%%=*}; pdst=${pd#*=}
        pbase=${psrc##*/}
        pid=${psrc#*/containers/}; pid=${pid%%/*}
        [ "$pdst" = "/etc/$pbase" ] || die "daemon plumbing '$pbase' grafted to '$pdst' (not docker's own mount)"
        [ -n "$cid" ] || die "plumbing bind but container id unparsed (fail-closed)"
        [ "$pid" = "$cid" ] || die "foreign container plumbing bind: $psrc (this container is $cid)"
    done
fi

old_ifs=$IFS
IFS='
'
# A bind source is checked TWICE: as written in the spec AND as the kernel
# will resolve it — a symlinked source ('ln -s / /workspace/link;
# -v /workspace/link') slips past literal-string policing because the kernel
# resolves symlink components at mount time: the guard sees the innocent
# literal, the mount gets the daemon's whole rootfs, rw. The guard runs in
# the daemon's mount namespace, so readlink -f here resolves exactly what the
# mount will use.
check_src() {
    case "$1" in
        /var/lib/docker/containerd*|/var/lib/docker/overlayfs*|/var/lib/docker/runtimes*)
            die "bind of daemon-internal path: $1" ;;
        /var/lib/docker/volumes/*|/var/lib/docker/buildkit/*|\
/var/lib/docker/containers/*/resolv.conf|/var/lib/docker/containers/*/hostname|\
/var/lib/docker/containers/*/hosts)
            return 0 ;;
    esac
    if [ -f "$CONF" ]; then
        for p in $(cat "$CONF"); do
            [ -z "$p" ] && continue
            case "$1" in "$p"|"$p"/*) return 0 ;; esac
        done
    fi
    die "bind source outside the allowed set: $1"
}
# Literal+readlink checks are TWO resolutions with a race window — a
# flipping symlink (atomic ln+mv) can make the guard sample 'safe' while the
# kernel mounts '/'. Closing it requires using the kernel's OWN resolution:
# for every source under an allowed (and therefore agent-writable) prefix,
# the guard first bind-mounts the source onto its own mountpoint, verifies
# from /proc/self/mountinfo WHICH (dev, root) the kernel actually resolved,
# and only then rewrites the spec to that mountpoint. A mountpoint cannot be
# swapped — rename onto it fails with EBUSY — so runc's later bind resolves
# exactly what was verified. Daemon-plumbing sources (volumes, buildkit,
# per-container files) are not pinned: their parent chains are root-owned and
# unreachable from nested containers. Pins live at the filesystem root
# ('/.pia-dind-guard') because a nested '-v /run:/host' recursive-binds /run —
# pins must never be reachable that way.
for sp in /.pia-dind-guard/pins/*; do
    [ -e "$sp" ] || continue
    umount -l "$sp" 2>/dev/null || umount "$sp" 2>/dev/null
    rmdir "$sp" 2>/dev/null || rm -f "$sp" 2>/dev/null
done
pin_i=0
for s in $("$JQ" -r '.mounts[]?.source // empty | select(startswith("/"))' "$cfg"); do
    check_src "$s"
    rs=$(readlink -f -- "$s" 2>/dev/null)
    [ -n "$rs" ] || die "bind source does not resolve: $s"
    [ "$rs" = "$s" ] || check_src "$rs"
    # Only root-owned, agent-unreachable sources skip pinning. Do NOT skip
    # '/var/lib/docker/*' wholesale: volumes/_data, buildkit and tmp/ are
    # agent-writable (via any container bind) — skipping them reopens the
    # race, especially under a conf that allows that whole tree.
    case "$rs" in
        /var/lib/docker/containers/*/resolv.conf|\
/var/lib/docker/containers/*/hostname|\
/var/lib/docker/containers/*/hosts) continue ;;
    esac
    under=""
    if [ -f "$CONF" ]; then
        for p in $(cat "$CONF"); do
            [ -z "$p" ] && continue
            case "$rs" in "$p"|"$p"/*) under="$p" ;; esac
        done
    fi
    # The hardcoded plumbing allowances are prefixes too (conf only carries
    # user-facing ones like /workspace) — without this, legit volume and
    # buildkit binds die at the pin stage.
    if [ -z "$under" ]; then
        for p in /var/lib/docker/volumes /var/lib/docker/buildkit; do
            case "$rs" in "$p"|"$p"/*) under="$p" ;; esac
        done
    fi
    [ -n "$under" ] || die "bind source matches no allowed prefix: $s"
    pin_i=$((pin_i + 1))
    pin="/.pia-dind-guard/pins/$$-$pin_i"
    if [ -f "$rs" ]; then
        mkdir -p /.pia-dind-guard/pins && touch "$pin" || die "cannot create pin for: $s"
    else
        mkdir -p "$pin" || die "cannot create pin for: $s"
    fi
    pins="$pins $pin"   # register BEFORE mount: mount-failure die() must clean it
    if ! mount -o bind "$s" "$pin"; then die "cannot pin bind source: $s"; fi
    # CRITICAL: the pin must not inherit the daemon's SHARED propagation —
    # a shared pin replicates into every namespace of that peer group, i.e.
    # into sibling containers (verified the damage: daemon-root pins visible
    # inside running containers, pins nesting into pins, umounts failing).
    mount --make-rprivate "$pin" || die "cannot make pin private: $s"
    mr=$(awk -v m="$pin" '$5==m{print $3" "$4; exit}' /proc/self/mountinfo)
    [ -n "$mr" ] || die "pin vanished: $s"
    pdev=${mr% *}; proot=${mr#* }
    ref=$(awk -v p="$under" 'BEGIN{ml=0}{mp=$5; if((mp==p||index(p,mp"/")==1)&&length(mp)>ml){ml=length(mp);d=$3;r=$4}}END{if(ml)print d" "r}' /proc/self/mountinfo)
    rdev=${ref% *}; rroot=${ref#* }
    ok=""
    case "$proot" in "$rroot"|"$rroot"/*) [ "$pdev" = "$rdev" ] && ok=1 ;; esac
    if [ -z "$ok" ]; then
        echo "$(date -u +%FT%TZ) pia-dind-guard: TOCTOU '$s' resolved to dev $pdev root '$proot' at mount time, outside '$under' (dev $rdev root '$rroot')" >> "$LOGF"
        die "TOCTOU: '$s' resolved outside '$under' at mount time"
    fi
    # Rewrite via jq: exact string equality on the source, no sed escaping
    # layer (a path containing quotes could confuse a text substitution).
    "$JQ" --arg old "$s" --arg new "$pin" \
        '(.mounts[] | select(.source==$old) | .source) = $new' \
        "$cfg" > "$cfg.pia" && mv "$cfg.pia" "$cfg" \
        || die "cannot rewrite spec for: $s"
done
IFS=$old_ifs
if [ -n "$pins" ]; then
    # Child-exec so the pins can be released afterwards (the container holds
    # its own copies; lazy umount is safe even if runc failed).
    "$REAL" "$@"
    rc=$?
    release_pins
    exit $rc
fi
exec "$REAL" "$@"
