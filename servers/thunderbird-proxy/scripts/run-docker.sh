#!/bin/bash

# Runs the docker-compose project

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="thunderbird-proxy"


###################################################################################################
# DEFINES
###################################################################################################

HERE="$(cd "$(dirname "$0")" && pwd)"


###################################################################################################
# MAIN
###################################################################################################

cd ${HERE}

if [ -f "../secrets/thunderbird-proxy-token.txt" ]; then
    export THUNDERBIRD_PROXY_TOKEN=$(cat ../secrets/thunderbird-proxy-token.txt)
else
    echo "[ERROR] secrets/thunderbird-proxy-token.txt missing — the proxy refuses to start without it."
    echo "[INFO]  Create it with: openssl rand -hex 32 > secrets/thunderbird-proxy-token.txt"
    exit 1
fi

if [ -f "../secrets/thunderbird-addon-token.txt" ]; then
    export THUNDERBIRD_ADDON_TOKEN=$(cat ../secrets/thunderbird-addon-token.txt)
else
    echo "[ERROR] secrets/thunderbird-addon-token.txt missing — the add-on face needs its own token."
    echo "[INFO]  Create it with: openssl rand -hex 32 > secrets/thunderbird-addon-token.txt"
    exit 1
fi

if [ -f "../secrets/thunderbird-addon-secret.txt" ]; then
    export THUNDERBIRD_ADDON_SECRET=$(cat ../secrets/thunderbird-addon-secret.txt)
else
    echo "[ERROR] secrets/thunderbird-addon-secret.txt missing — the add-on verifies signed responses with it."
    echo "[INFO]  Create it with: openssl rand -hex 32 > secrets/thunderbird-addon-secret.txt"
    exit 1
fi

if [ -f "../secrets/allowed-recipients.txt" ]; then
    export ALLOWED_SENDERS=$(tr '\n' ',' < ../secrets/allowed-recipients.txt)
fi

cd ../docker
docker compose -p ${PROJECT_NAME} up -d
