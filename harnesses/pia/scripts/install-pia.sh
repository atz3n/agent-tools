#!/bin/bash

# Copies pia script to ~/.local/bin/ so it is globally callable without the
# .sh suffix, and the embedded payload scripts (the nested-container guard)
# to ~/.pia/lib/, where the installed 'pia' finds them at runtime.
#
# Usage: bash install-pia.sh

###################################################################################################
# CONFIGURATION
###################################################################################################

SCRIPTS=("pia")


###################################################################################################
# DEFINES
###################################################################################################

HERE="$(pwd)/$(dirname $0)"
TARGET_DIR="$HOME/.local/bin"


###################################################################################################
# MAIN
###################################################################################################

# Target dir is not announced separately — each 'Installed:' line below
# already carries the full path.

# Ensure target directory exists
mkdir -p "${TARGET_DIR}"

for script in "${SCRIPTS[@]}"; do
    SRC="${HERE}/${script}.sh"
    DST="${TARGET_DIR}/${script}"

    if [ -f "${SRC}" ]; then
        rm -f "${DST}"
        cp "${SRC}" "${DST}"
        chmod +x "${DST}"
        echo "[INFO] Installed: ${DST}"
    else
        echo "[WARN] Source not found: ${SRC} — skipping."
    fi
done

# Only worth a line if it is actually a problem — the target dir is already
# printed above, so no repeating "done" message.
case ":${PATH}:" in
    *":${TARGET_DIR}:"*) ;;
    *) echo "[WARN] ${TARGET_DIR} is not in your PATH — add it to call 'pia' directly." ;;
esac

# The guard policy version is the marker on line 2 of docker/pia-dind/
# guard.sh; 'pia' reads it to derive the daemon image tag and to verify
# running daemons (recreate anything older). The CLI never builds — the
# daemon image comes from build-docker.sh — so the installed CLI needs ONLY
# guard.sh (the version), not the Dockerfile/entrypoint. An installed 'pia'
# is a plain copy in ~/.local/bin, not next to the repo, so guard.sh is
# mirrored here; a missing copy is fail-closed (no version, no daemon).
LIB_DIR="${HOME}/.pia/lib/pia-dind"
mkdir -p "${LIB_DIR}"
GUARD="${HERE}/../docker/pia-dind/guard.sh"
if [ -f "${GUARD}" ]; then
    cp "${GUARD}" "${LIB_DIR}/guard.sh"
    chmod +x "${LIB_DIR}/guard.sh"
    echo "[INFO] Installed: ${LIB_DIR}/guard.sh"
else
    echo "[WARN] guard.sh not found — 'pia --docker' will refuse to start daemons."
fi

