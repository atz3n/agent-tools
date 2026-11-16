#!/bin/bash

# Builds the pi harness Docker image
#
# Usage:
#   bash scripts/build-docker.sh [OPTIONS]
#
# Options:
#   -f, --force      Force a fresh build: ignore all cached layers (--no-cache)
#       --no-cache   Alias for --force
#   -h, --help       Display this help message

###################################################################################################
# CONFIGURATION
###################################################################################################

IMAGE_NAME="pia"


###################################################################################################
# DEFINES
###################################################################################################

HERE="$(pwd)/$(dirname $0)"
DOCKER_FILE="${HERE}/../docker/pia/Dockerfile"
CONTEXT_PATH="${HERE}/../../.."
DIND_DIR="${HERE}/../docker/pia-dind"
DIND_IMAGE_BASE="pia-dind"


###################################################################################################
# HELP
###################################################################################################

usage() {
    echo "Usage: $(basename $0) [OPTIONS]"
    echo ""
    echo "Builds the pi harness Docker image (${IMAGE_NAME}) and the nested-daemon"
    echo "image (${DIND_IMAGE_BASE}:guard-v<N>, tag derived from the guard policy"
    echo "version in docker/pia-dind/guard.sh). This is the ONLY place either"
    echo "image is built — the 'pia' CLI never builds, it requires both."
    echo ""
    echo "Options:"
    echo "  -f, --force      Force a fresh build: ignore all cached layers"
    echo "      --no-cache   Alias for --force"
    echo "  -h, --help       Display this help message"
}


###################################################################################################
# MAIN
###################################################################################################

BUILD_ARGS=()

for arg in "$@"; do
    case "$arg" in
        -f|--force|--no-cache)
            BUILD_ARGS+=(--no-cache)
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ ${#BUILD_ARGS[@]} -gt 0 ]; then
    echo "[INFO] Building image ${IMAGE_NAME} (forced, no cache)..."
else
    echo "[INFO] Building image ${IMAGE_NAME}..."
fi

docker build "${BUILD_ARGS[@]}" -f "${DOCKER_FILE}" "${CONTEXT_PATH}" -t "${IMAGE_NAME}"

# The throwaway-daemon image: context is the folder itself (Dockerfile,
# entrypoint.sh, guard.sh). The tag IS the guard policy version — editing
# the guard changes the tag, so the next 'build-docker.sh' produces a new
# image and 'pia' recreates daemons running older policy.
GUARD_VERSION="$(sed -n 's/^# pia-dind-guard GUARD_VERSION=\(.*\)/\1/p' "${DIND_DIR}/guard.sh" | head -1)"
if [ -z "${GUARD_VERSION}" ]; then
    echo "[ERROR] No GUARD_VERSION marker on line 2 of ${DIND_DIR}/guard.sh" >&2
    exit 1
fi
echo "[INFO] Building daemon image ${DIND_IMAGE_BASE}:guard-v${GUARD_VERSION}..."
docker build "${BUILD_ARGS[@]}" -t "${DIND_IMAGE_BASE}:guard-v${GUARD_VERSION}" "${DIND_DIR}"
echo "[INFO] Done."
