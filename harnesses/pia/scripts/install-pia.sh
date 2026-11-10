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

# Create the home '.pia' secrets folder. The installed 'pia' command is a
# plain copy in ~/.local/bin, so ~/.pia/secrets is where it looks for
# secrets — e.g. openrouter-key.txt, which 'pia run' injects into agent
# containers (see the README). The user places files here themselves. An
# existing folder is left untouched (no chmod); the hint about the key is
# shown last and whenever the key file is still missing — first install, or
# a later reinstall after the file was deleted or never added.
PIA_DIR="${HOME}/.pia"
SECRETS_DIR="${PIA_DIR}/secrets"
if [ ! -d "${SECRETS_DIR}" ]; then
    mkdir -p "${SECRETS_DIR}"
    chmod 700 "${SECRETS_DIR}"
fi
if [ ! -f "${SECRETS_DIR}/openrouter-key.txt" ]; then
    echo "[INFO] Add openrouter-key.txt to ${SECRETS_DIR} to use OpenRouter ('pia run --openrouter')"
fi
