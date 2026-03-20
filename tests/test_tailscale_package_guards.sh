#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }

grep -q 'test -d "./luci-app-tailscale-community"' "$PACKAGES_SH" || {
  echo "Packages.sh does not verify luci-app-tailscale-community extraction"
  exit 1
}

grep -q 'CONFIG_PACKAGE_luci-app-tailscale-community=y' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not verify tailscale community package remains enabled after defconfig"
  exit 1
}

echo "tailscale package guards test passed"
