#!/bin/bash

# Lints a project with ruff and pyright.

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="github-proxy"

RUN_RUFF=true
RUN_PYRIGHT=true
AUTO_FIX=false


###################################################################################################
# PARAMETER PARSING
###################################################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ruff)       RUN_RUFF=true; shift ;;
    --no-ruff)    RUN_RUFF=false; shift ;;
    --pyright)    RUN_PYRIGHT=true; shift ;;
    --no-pyright) RUN_PYRIGHT=false; shift ;;
    --fix)        AUTO_FIX=true; shift ;;
    --no-fix)     AUTO_FIX=false; shift ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --ruff       Run ruff lint check (default: enabled)"
      echo "  --no-ruff    Skip ruff lint check"
      echo "  --pyright    Run pyright type checking"
      echo "  --no-pyright Skip pyright type checking (default)"
      echo "  --fix        Auto-fix ruff errors where possible"
      echo "  --no-fix     Do not auto-fix (default)"
      echo "  --help       Display this help message"
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

echo "[INFO] Linting ${PROJECT_NAME}..."

if $RUN_RUFF; then
  echo "[INFO] Running ruff check..."
  if ! python -m ruff check . ; then
    FAILED=true
  fi

  if $AUTO_FIX; then
    echo "[INFO] Running ruff check --fix..."
    if ! python -m ruff check --fix . ; then
      FAILED=true
    fi
  fi
fi

if $RUN_PYRIGHT; then
  echo "[INFO] Running pyright..."
  if ! python -m pyright . ; then
    FAILED=true
  fi
fi

if $FAILED; then
  echo "[ERROR] Lint check failed."
  exit 1
fi

echo "[INFO] All lint checks passed."
