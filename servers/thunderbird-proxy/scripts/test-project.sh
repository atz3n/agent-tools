#!/bin/bash

# Runs the unit tests with unittest.

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="thunderbird-proxy"


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

HERE="$(cd "$(dirname "$0")" && pwd)"


###################################################################################################
# MAIN
###################################################################################################

cd "${HERE}/.."

FAILED=false

echo "[INFO] Testing ${PROJECT_NAME}..."

echo "[INFO] Running unittest..."
if ! python3 -m unittest discover -s tests -v ; then
  FAILED=true
fi

# Add-on dispatcher tests (plain-script commands.js loaded in a vm with a
# stubbed 'browser') — skipped loudly when node is unavailable.
if command -v node > /dev/null 2>&1; then
  echo "[INFO] Running add-on node tests..."
  if ! node --test addon/__test__/*.test.mjs ; then
    FAILED=true
  fi
else
  echo "[WARN] node not found — add-on node tests skipped."
fi

if $FAILED; then
  echo "[ERROR] Tests failed."
  exit 1
fi

echo "[INFO] All tests passed."
