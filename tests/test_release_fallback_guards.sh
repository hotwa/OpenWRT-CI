#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }

grep -q 'name: Upload Firmware Artifact' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not upload firmware artifacts before release"
  exit 1
}

grep -q 'uses: actions/upload-artifact@v4' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not use the official upload-artifact@v4 action"
  exit 1
}

grep -q 'uses: softprops/action-gh-release@v2' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not pin action-gh-release to @v2"
  exit 1
}

grep -q 'working_directory: ./wrt/upload' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not upload release assets from ./wrt/upload"
  exit 1
}

echo "release fallback guards test passed"
