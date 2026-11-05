#!/bin/bash

# Copies pia script to ~/.local/bin/ so it is globally callable without the .sh suffix.
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

echo "[INFO] Installing pi scripts to ${TARGET_DIR}..."

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

echo "[INFO] Done. Make sure ${TARGET_DIR} is in your PATH."
