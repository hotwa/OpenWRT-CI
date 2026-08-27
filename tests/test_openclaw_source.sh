#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }

grep -Fq '# OPENCLAW_PACKAGE_COMMIT=' "$PACKAGES_SH" || {
  echo "openclaw package should be disabled/commented out"
  exit 1
}
grep -Fq '# UPDATE_PACKAGE "openclaw"' "$PACKAGES_SH" || {
  echo "openclaw update package should be commented out"
  exit 1
}

echo "openclaw source disabled guard test passed"
