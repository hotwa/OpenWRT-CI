#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
HANDLES_SH="$ROOT_DIR/Scripts/Handles.sh"
TAILSCALE_CONFIG="$ROOT_DIR/files/etc/config/tailscale"
TAILSCALE_UCI_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/96-tailscale-uci-fallback"
TAILSCALE_DNS_GUARD="$ROOT_DIR/files/etc/init.d/tailscale-accept-dns-guard"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$HANDLES_SH" ] || { echo "missing Handles.sh"; exit 1; }
[ -f "$TAILSCALE_CONFIG" ] || { echo "missing default tailscale UCI config overlay"; exit 1; }
[ -f "$TAILSCALE_UCI_DEFAULTS" ] || { echo "missing tailscale UCI fallback defaults script"; exit 1; }
[ -f "$TAILSCALE_DNS_GUARD" ] || { echo "missing tailscale DNS guard init script"; exit 1; }

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

grep -q "^config settings 'settings'$" "$TAILSCALE_CONFIG" || {
  echo "default tailscale UCI config overlay is missing the settings section"
  exit 1
}

grep -q "^	option fw_mode 'nftables'$" "$TAILSCALE_CONFIG" || {
  echo "default tailscale UCI config overlay is missing fw_mode nftables"
  exit 1
}

grep -q '\[ -f "/etc/config/tailscale" \] && exit 0' "$TAILSCALE_UCI_DEFAULTS" || {
  echo "tailscale UCI fallback defaults script does not preserve existing config"
  exit 1
}

grep -q "config settings 'settings'" "$TAILSCALE_UCI_DEFAULTS" || {
  echo "tailscale UCI fallback defaults script does not recreate the settings section"
  exit 1
}

grep -q '/etc/config/tailscale' "$TAILSCALE_DNS_GUARD" || {
  echo "tailscale DNS guard does not ensure the runtime UCI config exists"
  exit 1
}

echo "tailscale package guards test passed"
