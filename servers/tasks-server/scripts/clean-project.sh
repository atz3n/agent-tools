#!/bin/bash

# Removes build artifacts (__pycache__, .ruff_cache, .mypy_cache, etc.)
# from a project.

###################################################################################################
# CONFIGURATION
###################################################################################################

DRY_RUN=false


###################################################################################################
# PARAMETER PARSING
###################################################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --dry-run  Show what would be deleted without deleting"
      echo "  --help     Display this help message"
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

HERE="$(cd "$(dirname $0)/.." && pwd)"

FIND_ARGS=()
FIND_ARGS+=("${HERE}")
FIND_ARGS+=("-type")
FIND_ARGS+=("d")
FIND_ARGS+=("(")
FIND_ARGS+=("-name")
FIND_ARGS+=("__pycache__")
FIND_ARGS+=("-o")
FIND_ARGS+=("-name")
FIND_ARGS+=(".ruff_cache")
FIND_ARGS+=("-o")
FIND_ARGS+=("-name")
FIND_ARGS+=(".mypy_cache")
FIND_ARGS+=("-o")
FIND_ARGS+=("-name")
FIND_ARGS+=(".pytest_cache")
FIND_ARGS+=(")")
FIND_ARGS+=("-prune")
FIND_ARGS+=("-exec")
FIND_ARGS+=("rm")
FIND_ARGS+=("-rf")
FIND_ARGS+=("{}")
FIND_ARGS+=("+")


###################################################################################################
# MAIN
###################################################################################################

if $DRY_RUN; then
  echo "[INFO] Dry run — would delete:"
  find "${FIND_ARGS[@]}" -exec echo "  {}" \;
else
  echo "[INFO] Removing build artifacts in ${HERE}..."
  find "${FIND_ARGS[@]}" -exec rm -rf {} +
  echo "[INFO] Done."
fi
