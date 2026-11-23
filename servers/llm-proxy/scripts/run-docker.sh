#!/bin/bash

# Runs the docker-compose project

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="llm-proxy"


###################################################################################################
# DEFINES
###################################################################################################

HERE="$(cd "$(dirname "$0")" && pwd)"


###################################################################################################
# MAIN
###################################################################################################

cd ${HERE}

if [ -f "../secrets/openrouter-api-key.txt" ]; then
    export OPENROUTER_API_KEY=$(cat ../secrets/openrouter-api-key.txt)
else
    echo "[Warning] openrouter-api-key.txt missing — the /openrouter route will be disabled."
fi

if [ -f "../secrets/llm-proxy-token.txt" ]; then
    export LLM_PROXY_TOKEN=$(cat ../secrets/llm-proxy-token.txt)
fi

cd ../docker
docker compose -p ${PROJECT_NAME} up -d
