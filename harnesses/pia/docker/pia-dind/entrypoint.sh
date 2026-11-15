#!/bin/sh
# pia-dind entrypoint — prepares the nested-container guard, then execs the
# UPSTREAM docker-entrypoint unchanged (so this image behaves exactly like
# docker:29-dind otherwise; CMD is inherited).
#
# Why this runs at container start instead of image build:
#   * the immutable flag (chattr +i) cannot survive image layer export — it
#     has to be set inside the running container, on its own overlay upper;
#   * the bind whitelist is per-mode (plain dind vs dind-dev workspace),
#     decided when 'pia' starts this daemon, passed in via $PIA_GUARD_WS.
# Ordering guarantee: this runs BEFORE dockerd starts, so no nested
# container can ever exist that was not created through the guard.
set -eu

CONF=/usr/local/etc/pia-dind-guard.conf
GUARD_SRC=/usr/local/lib/pia-dind/guard.sh

# 1) Bind whitelist the guard enforces: dind-dev passes the workspace
#    target, plain dind leaves it empty (Docker plumbing only). Rewriting
#    after a restart needs the immutability cleared first.
mkdir -p /usr/local/etc
chattr -i "$CONF" 2>/dev/null || true
printf '%s\n' "${PIA_GUARD_WS:-}" > "$CONF"

# 2) Install the guard AS runc (the real binary lives on as '<runc>.real').
#    Idempotent across restarts: the container layer keeps runc.real.
rp="$(command -v runc 2>/dev/null || echo /usr/local/bin/runc)"
chattr -i "$rp" "${rp}.real" 2>/dev/null || true
if [ ! -f "${rp}.real" ]; then
    mv "$rp" "${rp}.real"
fi
cp "$GUARD_SRC" "$rp"
chmod 0755 "$rp"

# 3) Tamper-proofing: a workload that somehow reaches the
#    daemon filesystem cannot patch the guard, its source copy, the
#    whitelist, or the jq parser in place. Clearing +i needs daemon root +
#    CAP_LINUX_IMMUTABLE, which the guard policy makes unreachable.
chattr +i "$rp" "${rp}.real" "$GUARD_SRC" "$CONF" /usr/bin/jq 2>/dev/null || true

exec /usr/local/bin/dockerd-entrypoint.sh "$@"
