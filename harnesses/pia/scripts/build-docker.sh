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
DOCKER_FILE="${HERE}/../docker/Dockerfile"
CONTEXT_PATH="${HERE}/../../.."


###################################################################################################
# HELP
###################################################################################################

usage() {
    echo "Usage: $(basename $0) [OPTIONS]"
    echo ""
    echo "Builds the pi harness Docker image (${IMAGE_NAME})."
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
echo "[INFO] Done."
