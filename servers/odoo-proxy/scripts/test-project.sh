#!/bin/bash

# Runs the unit tests with unittest.

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="odoo-proxy"


###################################################################################################
# PARAMETER PARSING
###################################################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --help  Display this help message"
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1"
      echo "Run '$0 --help' for usage."
      exit 1
      ;;
  esac
done


###################################################################################################
# DEFINES
###################################################################################################

HERE="$(pwd)/$(dirname $0)"


###################################################################################################
# MAIN
###################################################################################################

cd "${HERE}/.."

FAILED=false

echo "[INFO] Testing ${PROJECT_NAME}..."

echo "[INFO] Running unittest..."
if ! python -m unittest discover -s tests -v ; then
  FAILED=true
fi

if $FAILED; then
  echo "[ERROR] Tests failed."
  exit 1
fi

echo "[INFO] All tests passed."
