#!/bin/bash

# Packages the Thunderbird add-on (addon/) into an .xpi that can be installed
# through Thunderbird's "Install Add-on From File" dialog. Dev-only files
# (__test__/, dotfiles, previously built archives) are excluded; the archive is
# named after the version in addon/manifest.json.

###################################################################################################
# CONFIGURATION
###################################################################################################

ADDON_NAME="thunderbird-proxy-bridge"


###################################################################################################
# PARAMETER PARSING
###################################################################################################

OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "[ERROR] Option '$1' requires a value."
        exit 1
      fi
      OUT_DIR="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --out DIR  Output directory (default: <project>/dist)"
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

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ADDON_DIR="${HERE}/addon"
MANIFEST="${ADDON_DIR}/manifest.json"
[ -n "${OUT_DIR}" ] || OUT_DIR="${HERE}/dist"


###################################################################################################
# MAIN
###################################################################################################

if [ ! -f "${MANIFEST}" ]; then
  echo "[ERROR] Add-on manifest not found: ${MANIFEST}"
  exit 1
fi

echo "[INFO] Packaging ${ADDON_DIR}..."
if ! python3 - "${ADDON_DIR}" "${OUT_DIR}" "${ADDON_NAME}" <<'PY'
import json, os, sys
from zipfile import ZIP_DEFLATED, ZipFile

addon_dir, out_dir, name = sys.argv[1], sys.argv[2], sys.argv[3]

with open(os.path.join(addon_dir, "manifest.json"), encoding="utf-8") as fh:
    manifest = json.load(fh)
version = manifest["version"]

files = []
for root, dirs, names in os.walk(addon_dir):
    dirs[:] = sorted(d for d in dirs if d != "__test__" and not d.startswith("."))
    files += [os.path.relpath(os.path.join(root, n), addon_dir)
              for n in sorted(names)
              if not n.startswith(".") and not n.endswith(".xpi")]

if "manifest.json" not in files:
    sys.exit("manifest.json is missing from the add-on")

os.makedirs(out_dir, exist_ok=True)
out_file = os.path.join(out_dir, f"{name}-{version}.xpi")
with ZipFile(out_file, "w", ZIP_DEFLATED) as xpi:
    for rel in files:
        xpi.write(os.path.join(addon_dir, rel), rel)

print(f"[INFO]   {out_file}")
print(f"[INFO]   {len(files)} files, manifest version {version}")
PY
then
  echo "[ERROR] Packaging failed."
  exit 1
fi

echo "[INFO] Install it via Add-ons and Themes -> gear -> Install Add-on From File."
echo "[INFO] Done."
