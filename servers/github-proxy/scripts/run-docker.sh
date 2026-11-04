#!/bin/bash

# Runs the docker-compose project

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="gh-proxy"


###################################################################################################
# DEFINES
###################################################################################################

HERE="$(pwd)/$(dirname $0)"


###################################################################################################
# MAIN
###################################################################################################

cd ${HERE}

if [ ! -f "../secrets/github-personal-access-token.txt" ]; then
    echo "[Error] github-personal-access-token.txt missing"
    exit 1
fi

export GITHUB_PERSONAL_ACCESS_TOKEN=$(cat ../secrets/github-personal-access-token.txt)

cd ../docker
docker compose -p ${PROJECT_NAME} up -d
