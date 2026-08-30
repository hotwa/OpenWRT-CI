#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }

if grep -Eq '^[[:space:]]*UPDATE_PACKAGE[[:space:]]+"openclaw"' "$PACKAGES_SH"; then
  echo "OpenClaw source fetch must remain disabled"
  exit 1
fi

echo "OpenClaw source remains disabled"
