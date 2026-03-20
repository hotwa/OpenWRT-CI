#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
HANDLES_SH="$ROOT_DIR/Scripts/Handles.sh"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$HANDLES_SH" ] || { echo "missing Handles.sh"; exit 1; }

grep -q 'test -d "./luci-app-tailscale-community"' "$PACKAGES_SH" || {
  echo "Packages.sh does not verify luci-app-tailscale-community extraction"
  exit 1
}

grep -q 'CONFIG_PACKAGE_tailscale=y' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not verify tailscale remains enabled after defconfig"
  exit 1
}

grep -q 'CONFIG_PACKAGE_luci-app-tailscale-community=y' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not verify tailscale community package remains enabled after defconfig"
  exit 1
}

if grep -q 'sed -i '\''/\\/files/d'\'' \$TS_FILE' "$HANDLES_SH"; then
  echo "Handles.sh still strips tailscale package files, which removes /etc/config/tailscale at runtime"
  exit 1
fi

echo "tailscale package guards test passed"
