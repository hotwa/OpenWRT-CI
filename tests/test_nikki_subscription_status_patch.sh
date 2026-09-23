#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES="$ROOT_DIR/Scripts/Packages.sh"
FIX_SCRIPT="$ROOT_DIR/Scripts/patch_nikki_subscription_status.sh"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$FIX_SCRIPT" ] || { echo 'missing Nikki status fix' >&2; exit 1; }
sh -n "$FIX_SCRIPT"
grep -Fxq 'NIKKI_PACKAGE_COMMIT=7b203f6c4c5e94c6c0026acb301090aa1d310e7f' "$PACKAGES"
grep -Fq 'UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main" "" "" "$NIKKI_PACKAGE_COMMIT"' "$PACKAGES"
grep -Fq 'sh "$NIKKI_UPDATE_STATUS_FIX" "$NIKKI_PACKAGE_DIR/files/nikki.init"' "$PACKAGES"
grep -Fq 'return 1' "$FIX_SCRIPT"
grep -Fq 'CONFIG_PACKAGE_flock=y' "$ROOT_DIR/Config/GENERAL.txt"
grep -Fq "path '*/nikki/files/nikki.init'" "$CORE"
grep -Fq 'Nikki subscription update must return failure when download validation fails' "$CORE"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/files"
printf '%s\n' \
  'update_subscription() {' \
  'elif [ "$success" = 0 ]; then' \
  '  log "Profile" "Subscription update failed."' \
  '  uci_set "nikki" "$subscription_section" "success" "0"' \
  $'\tuci_commit "nikki"' \
  '}' >"$WORK_DIR/files/nikki.init"
sh "$FIX_SCRIPT" "$WORK_DIR/files/nikki.init"
grep -Fq 'return 0' "$WORK_DIR/files/nikki.init"
grep -Fq 'return 1' "$WORK_DIR/files/nikki.init"

echo 'nikki subscription status patch test passed'
