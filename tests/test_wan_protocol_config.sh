#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/ConfigureWanProtocol.sh"
GUARD="$ROOT_DIR/Scripts/PrivateFirmwareGuard.sh"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
DOC="$ROOT_DIR/docs/wan-action-inputs.md"

for path in "$SCRIPT" "$GUARD"; do
  [ -f "$path" ] || { echo "missing $path"; exit 1; }
  bash -n "$path"
done
[ -f "$DOC" ] || { echo 'missing WAN Action input documentation'; exit 1; }

grep -Fq 'WRT_WAN_PROTOCOL:' "$CORE"
grep -Fq 'OPENWRT_WAN_PPPOE_USERNAME' "$CORE"
grep -Fq 'OPENWRT_WAN_PPPOE_PASSWORD' "$CORE"
grep -Fq 'ConfigureWanProtocol.sh' "$CORE"
grep -Fq 'OPENWRT_WAN_PPPOE_PASSWORD' "$DOC"
for workflow in \
  "$ROOT_DIR/.github/workflows/QCA-6.18-VIKINGYFY.yml" \
  "$ROOT_DIR/.github/workflows/RE-CS-07-BUILD.yml" \
  "$ROOT_DIR/.github/workflows/WLG-RE-CS-07-BUILD.yml" \
  "$ROOT_DIR/.github/workflows/RE-Mesh-BUILD.yml" \
  "$ROOT_DIR/.github/workflows/CPE-5G.yml"; do
  grep -Fq 'WAN_PROTOCOL:' "$workflow" || { echo "missing WAN protocol input: $workflow"; exit 1; }
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

WRT_WAN_PROTOCOL=dhcp "$SCRIPT" "$WORK_DIR/dhcp"
test ! -e "$WORK_DIR/dhcp/etc/uci-defaults/97-wan-pppoe"

OPENWRT_WAN_PPPOE_USERNAME='test-user' \
OPENWRT_WAN_PPPOE_PASSWORD='test-password' \
WRT_WAN_PROTOCOL=pppoe "$SCRIPT" "$WORK_DIR/pppoe" >"$WORK_DIR/inject.log"
DEFAULTS="$WORK_DIR/pppoe/etc/uci-defaults/97-wan-pppoe"
[ -x "$DEFAULTS" ] || { echo 'PPPoE UCI defaults is not executable'; exit 1; }
grep -Fq 'network.wan.proto=pppoe' "$DEFAULTS"
grep -Fq 'base64 -d' "$DEFAULTS"
if grep -Fq 'test-user' "$DEFAULTS" "$WORK_DIR/inject.log" || grep -Fq 'test-password' "$DEFAULTS" "$WORK_DIR/inject.log"; then
  echo 'PPPoE credentials leaked in plaintext during build injection'
  exit 1
fi

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_CALLS"
EOF
chmod 755 "$WORK_DIR/bin/uci"
TEST_CALLS="$WORK_DIR/uci.calls" PATH="$WORK_DIR/bin:$PATH" sh "$DEFAULTS"
grep -Fxq 'set network.wan.proto=pppoe' "$WORK_DIR/uci.calls"
grep -Fxq 'set network.wan.username=test-user' "$WORK_DIR/uci.calls"
grep -Fxq 'set network.wan.password=test-password' "$WORK_DIR/uci.calls"
grep -Fxq 'commit network' "$WORK_DIR/uci.calls"

bash "$GUARD" "$WORK_DIR/pppoe" >"$WORK_DIR/private.env" 2>"$WORK_DIR/private.log"
grep -Fxq 'WRT_PRIVATE_BUILD=true' "$WORK_DIR/private.env"
grep -Fq 'wan-pppoe-credential' "$WORK_DIR/private.env"
if grep -Fq 'test-password' "$WORK_DIR/private.env" "$WORK_DIR/private.log"; then
  echo 'PPPoE private guard leaked a credential'
  exit 1
fi

if WRT_WAN_PROTOCOL=pppoe "$SCRIPT" "$WORK_DIR/missing" >/dev/null 2>&1; then
  echo 'PPPoE injection accepted missing credentials'
  exit 1
fi

echo 'WAN protocol configuration test passed'
