#!/bin/bash

# Runs the odoo-proxy Docker container

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="odoo-proxy"


###################################################################################################
# DEFINES
###################################################################################################

HERE="$(pwd)/$(dirname $0)"


###################################################################################################
# MAIN
###################################################################################################

cd ${HERE}

# Read credentials from secret files and export as environment variables
for secret in db url user password; do
    if [ ! -f "../secrets/odoo-${secret}.txt" ]; then
        echo "[Error] secrets/odoo-${secret}.txt missing"
        exit 1
    fi
done

export ODOO_DB="$(cat ../secrets/odoo-db.txt)"
export ODOO_URL="$(cat ../secrets/odoo-url.txt)"
export ODOO_USER="$(cat ../secrets/odoo-user.txt)"
export ODOO_PASSWORD="$(cat ../secrets/odoo-password.txt)"

cd ../docker
docker compose -p ${PROJECT_NAME} up -d
