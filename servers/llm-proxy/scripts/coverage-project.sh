#!/bin/bash

# Runs the unit tests under coverage.py and fails if coverage drops below the
# fail_under threshold configured in pyproject.toml.

###################################################################################################
# CONFIGURATION
###################################################################################################

PROJECT_NAME="llm-proxy"
PACKAGE="llm_proxy"

###################################################################################################
# PARAMETER PARSING
###################################################################################################

HTML_REPORT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --html)
      HTML_REPORT=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --html    Also write an HTML report to htmlcov/"
      echo "  --help    Display this help message"
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

echo "[INFO] Measuring coverage for ${PROJECT_NAME}..."

if ! python3 -c "import coverage" 2>/dev/null; then
  echo "[ERROR] coverage is not installed. Run: pip install coverage"
  exit 1
fi

rm -rf .coverage htmlcov

if ! python3 -m coverage run --source="${PACKAGE}" -m unittest discover -s tests; then
  echo "[ERROR] Tests failed."
  exit 1
fi

echo "[INFO] Coverage report:"
if ! python3 -m coverage report -m; then
  echo "[ERROR] Coverage below threshold."
  exit 1
fi

if $HTML_REPORT; then
  echo "[INFO] Writing HTML report to htmlcov/..."
  python3 -m coverage html
fi

echo "[INFO] Coverage check passed."
