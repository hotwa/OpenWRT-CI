#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/ConfigureCpe5G.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ -x "$SCRIPT" ] || {
  echo "missing executable ConfigureCpe5G.sh"
  exit 1
}

mkdir -p "$TMP_DIR/disabled" "$TMP_DIR/enabled"
"$SCRIPT" "$TMP_DIR/disabled" false
[ ! -e "$TMP_DIR/disabled/etc/uci-defaults/92-cpe-5g-network" ] || {
  echo "disabled CPE network bootstrap must not create an overlay"
  exit 1
}

"$SCRIPT" "$TMP_DIR/enabled" true
BOOTSTRAP="$TMP_DIR/enabled/etc/uci-defaults/92-cpe-5g-network"
[ -x "$BOOTSTRAP" ] || {
  echo "enabled CPE network bootstrap is missing or not executable"
  exit 1
}

grep -q "uci set network.5G='interface'" "$BOOTSTRAP"
grep -q "uci set network.5G.device='usb0'" "$BOOTSTRAP"
grep -q "uci set network.5G.proto='dhcp'" "$BOOTSTRAP"
grep -q "uci set network.5G.defaultroute='0'" "$BOOTSTRAP"
grep -q "uci add_list firewall.\$wan_zone.network='5G'" "$BOOTSTRAP"
grep -q "uci add firewall forwarding" "$BOOTSTRAP"
grep -q "uci set firewall.\$forwarding.src='lan'" "$BOOTSTRAP"
grep -q "uci set firewall.\$forwarding.dest='wan'" "$BOOTSTRAP"
sh -n "$BOOTSTRAP"

if "$SCRIPT" "$TMP_DIR/enabled" invalid >/dev/null 2>&1; then
  echo "invalid CPE network bootstrap flag must fail"
  exit 1
fi

echo "CPE-5G network bootstrap test passed"
