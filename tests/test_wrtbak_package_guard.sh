#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
WRT_CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$GENERAL" ] || { echo "missing GENERAL config"; exit 1; }
[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }
[ -f "$WRT_CORE" ] || { echo "missing WRT-CORE workflow"; exit 1; }

grep -q '^CONFIG_PACKAGE_luci-app-wrtbak=y$' "$GENERAL" || {
  echo "GENERAL config does not enable luci-app-wrtbak"
  exit 1
}

grep -q '^UPDATE_PACKAGE "luci-app-wrtbak" "hotwa/luci-app-wrtbak" "main"$' "$PACKAGES_SH" || {
  echo "Packages.sh does not pull luci-app-wrtbak from hotwa/luci-app-wrtbak main"
  exit 1
}

grep -q 'CONFIG_PACKAGE_luci-app-wrtbak=y' "$WRT_CORE" || {
  echo "WRT-CORE does not verify luci-app-wrtbak remains enabled after defconfig"
  exit 1
}

echo "wrtbak package guard passed"
