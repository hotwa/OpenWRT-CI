#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$ROOT_DIR/files/usr/sbin/tailscale-state-persist"
INIT="$ROOT_DIR/files/etc/init.d/tailscale-state-persist"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/97-tailscale-state-persist"
HOTPLUG="$ROOT_DIR/files/etc/hotplug.d/block/99-tailscale-state-persist"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

for path in "$WORKER" "$INIT" "$DEFAULTS" "$HOTPLUG"; do
  [ -f "$path" ] || { echo "missing $path"; exit 1; }
  sh -n "$path"
done

grep -Fq 'START=96' "$INIT"
grep -Fq '/data/tailscale/tailscaled.state' "$ROOT_DIR/files/etc/config/tailscale"
grep -Fq 'tailscale-state-persist' "$WORKFLOW"
grep -Fq 'data_is_persistent_mount' "$WORKER"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
BIN_DIR="$WORK_DIR/bin"
DATA_ROOT="$WORK_DIR/data"
STATE_DIR="$DATA_ROOT/tailscale"
STATE_FILE="$STATE_DIR/tailscaled.state"
LEGACY="$WORK_DIR/legacy/tailscaled.state"
MOUNTS="$WORK_DIR/mounts"
CALLS="$WORK_DIR/calls"
READY_FILE="$WORK_DIR/tailscale-state.ready"
mkdir -p "$BIN_DIR" "$(dirname "$LEGACY")" "$DATA_ROOT"
printf '%s\n' 'legacy-node-state' >"$LEGACY"
printf '/dev/mmcblk0p27 %s ext4 rw 0 0\n' "$DATA_ROOT" >"$MOUNTS"

cat >"$BIN_DIR/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_CALLS"
case "$1 $2" in
  '-q get') printf '%s\n' '/etc/tailscale/tailscaled.state' ;;
esac
EOF
cat >"$BIN_DIR/tailscale-init" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >>"$TEST_CALLS"
EOF
cat >"$BIN_DIR/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$BIN_DIR"/*

run_worker() {
  TEST_CALLS="$CALLS" PATH="$BIN_DIR:$PATH" \
  TAILSCALE_STATE_DATA_ROOT="$DATA_ROOT" \
  TAILSCALE_STATE_DIR="$STATE_DIR" \
  TAILSCALE_STATE_FILE="$STATE_FILE" \
  TAILSCALE_LEGACY_STATE_FILE="$LEGACY" \
  TAILSCALE_STATE_MOUNTS_FILE="$MOUNTS" \
  TAILSCALE_STATE_INIT="$BIN_DIR/tailscale-init" \
  TAILSCALE_STATE_LOCK_DIR="$WORK_DIR/lock" \
	TAILSCALE_STATE_READY_FILE="$READY_FILE" \
  "$WORKER"
}

run_worker
cmp "$LEGACY" "$STATE_FILE"
grep -Fq "set tailscale.settings.state_file=$STATE_FILE" "$CALLS"
grep -Fxq 'init stop' "$CALLS"
grep -Fxq 'init start' "$CALLS"
[ "$(stat -c %a "$STATE_DIR")" = 700 ]
[ "$(stat -c %a "$STATE_FILE")" = 600 ]
[ -f "$READY_FILE" ]

printf '%s\n' 'persisted-authoritative-state' >"$STATE_FILE"
printf '%s\n' 'newer-legacy-state-must-not-overwrite' >"$LEGACY"
: >"$CALLS"
run_worker
grep -Fxq 'persisted-authoritative-state' "$STATE_FILE"
! grep -Fxq 'init stop' "$CALLS"

rm -rf "$STATE_DIR"
printf 'tmpfs %s tmpfs rw 0 0\n' "$DATA_ROOT" >"$MOUNTS"
: >"$CALLS"
run_worker
test ! -e "$STATE_FILE"
test ! -e "$READY_FILE"
grep -Fxq 'init stop' "$CALLS"

echo 'tailscale state persistence test passed'
