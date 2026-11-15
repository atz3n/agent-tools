# pia-dind — the throwaway nested Docker daemon image for 'pia --docker'.
#
# A thin derived image over the upstream docker:29-dind, digest-pinned so
# the base is exact and auditable ('docker history' shows every addition).
# It bakes in exactly two things:
#   * jq — the JSON parser the nested-container guard uses to read the OCI
#     spec (Alpine's own signed package, musl-native; the upstream jqlang
#     linux binaries are glibc builds and do NOT run here), and
#   * the guard (guard.sh) + entrypoint that installs it as the daemon's
#     runc at startup.
# Building this image is what replaced runtime payload injection: the image
# digest IS the policy bundle (daemon + guard + parser). The CLI still
# VERIFIES a running daemon carries the expected guard version — baking
# removes injection, not trust-but-verify (see docs/docker.md).
#
# Build context: this folder only.
FROM docker:29-dind@sha256:08a98015fce594af7c382883bea080ea206de74402a95da9dc52b6428c8cd121

# Pin the exact package version: if Alpine's community repo drops it the
# build FAILS LOUDLY (a stale-policy image must never build silently —
# bump the pin deliberately after checking 'apk info -v jq').
RUN apk add --no-cache jq=1.8.2-r0

# The guard is COPY'd, not installed as runc here: the swap happens at
# container start (entrypoint) because the immutable flag cannot survive
# image layer export, and the conf is per-mode (env-driven).
COPY guard.sh /usr/local/lib/pia-dind/guard.sh
RUN chmod 0755 /usr/local/lib/pia-dind/guard.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Wrapper entrypoint: writes the bind whitelist from $PIA_GUARD_WS, swaps
# the guard in as runc, makes the policy files immutable, then execs the
# UPSTREAM entrypoint with the original arguments (CMD is inherited, so
# 'docker run pia-dind' behaves exactly like 'docker run docker:29-dind').
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
