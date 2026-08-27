#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }

grep -Fq 'OPENCLAW_PACKAGE_COMMIT=904e7df084735382d152ae74a32935e6e0a1202d' "$PACKAGES_SH" || {
  echo "openclaw source commit is not pinned"
  exit 1
}
grep -Fq 'UPDATE_PACKAGE "openclaw" "hotwa/luci-app-openclaw" "main" "" "" "$OPENCLAW_PACKAGE_COMMIT"' "$PACKAGES_SH" || {
  echo "openclaw source is not pinned to the reviewed hotwa commit"
  exit 1
}

echo "openclaw source test passed"
