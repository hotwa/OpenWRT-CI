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
grep -Fxq '/usr/sbin/tailscale-state-persist >/dev/null 2>&1 || true' "$HOTPLUG"
! grep -q 'init.d/tailscale-state-persist restart' "$HOTPLUG"

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

CURRENT_CONFIG="$WORK_DIR/current-state-file"
printf '%s\n' '/etc/tailscale/tailscaled.state' >"$CURRENT_CONFIG"
cat >"$BIN_DIR/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_CALLS"
case "$1 $2" in
  '-q get') cat "$TEST_CONFIG" 2>/dev/null ;;
  '-q set') printf '%s\n' "${3#*=}" >"$TEST_CONFIG" ;;
esac
EOF
cat >"$BIN_DIR/tailscale-init" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >>"$TEST_CALLS"
case "$1" in
  running) [ -f "$TEST_RUNNING" ] ;;
  stop) [ "${TEST_STOP_FAIL:-0}" != 1 ] && rm -f "$TEST_RUNNING" ;;
  start)
    # Publishing readiness before tailscaled starts would release enrollment
    # against a daemon that still uses the legacy identity.
    [ ! -e "$TEST_READY" ] || exit 20
    [ "$(cat "$TEST_CONFIG")" = "$TEST_STATE" ] || exit 21
    [ "${TEST_START_FAIL:-0}" != 1 ] && touch "$TEST_RUNNING"
    ;;
esac
EOF
cat >"$BIN_DIR/ln" <<'EOF'
#!/bin/sh
# Simulate an independent daemon creating an identity during the copy.
if [ "${TEST_STATE_RACE:-0}" = 1 ]; then
  printf '%s\n' 'concurrent-authoritative-state' >"$TEST_STATE"
fi
exec /bin/ln "$@"
EOF
cat >"$BIN_DIR/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$BIN_DIR"/*

run_worker() {
  TEST_CALLS="$CALLS" TEST_CONFIG="$CURRENT_CONFIG" \
  TEST_STATE="$STATE_FILE" TEST_READY="$READY_FILE" TEST_RUNNING="$WORK_DIR/running" PATH="$BIN_DIR:$PATH" \
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
[ "$(grep '^init ' "$CALLS" | tr '\n' ',')" = 'init stop,init enable,init running,init start,' ]
[ "$(stat -c %a "$STATE_DIR")" = 700 ]
[ "$(stat -c %a "$STATE_FILE")" = 600 ]
[ -f "$READY_FILE" ]

# An existing /data identity is authoritative, but an old configured daemon
# must still be stopped and started so it actually switches to that identity.
printf '%s\n' 'persisted-authoritative-state' >"$STATE_FILE"
printf '%s\n' 'newer-legacy-state-must-not-overwrite' >"$LEGACY"
printf '%s\n' '/etc/tailscale/tailscaled.state' >"$CURRENT_CONFIG"
: >"$CALLS"
run_worker
grep -Fxq 'persisted-authoritative-state' "$STATE_FILE"
grep -Fxq 'init stop' "$CALLS"
[ "$(cat "$CURRENT_CONFIG")" = "$STATE_FILE" ]

# An unchanged persistent-state path needs no stop on a repeated block event.
: >"$CALLS"
run_worker
! grep -Fxq 'init stop' "$CALLS"
! grep -Fxq 'init start' "$CALLS"
[ -f "$READY_FILE" ]

# Concurrent events must not clear the active worker's readiness.
mkdir "$WORK_DIR/lock"
: >"$CALLS"
run_worker
[ -f "$READY_FILE" ]
[ ! -s "$CALLS" ]
rmdir "$WORK_DIR/lock"
# A stopped service still recovers with the authoritative identity.
rm -f "$WORK_DIR/running"
: >"$CALLS"
run_worker
grep -Fxq 'init start' "$CALLS"
# A running daemon must stop/start when its configured path changes.
printf '%s\n' '/etc/tailscale/tailscaled.state' >"$CURRENT_CONFIG"
: >"$CALLS"
run_worker
grep -Fxq 'init stop' "$CALLS"
grep -Fxq 'init start' "$CALLS"

rm -f "$WORK_DIR/running"
: >"$CALLS"
if TEST_START_FAIL=1 run_worker; then
  echo 'failed tailscaled start must fail the persistence worker' >&2
  exit 1
fi
[ ! -e "$READY_FILE" ]
grep -Fxq 'persisted-authoritative-state' "$STATE_FILE"

printf '%s\n' '/etc/tailscale/tailscaled.state' >"$CURRENT_CONFIG"
: >"$CALLS"
if TEST_STOP_FAIL=1 run_worker; then
  echo 'failed tailscaled stop must hold migration' >&2
  exit 1
fi
[ ! -e "$READY_FILE" ]
[ "$(cat "$CURRENT_CONFIG")" = '/etc/tailscale/tailscaled.state' ]
! grep -Fxq 'init start' "$CALLS"
grep -Fxq 'persisted-authoritative-state' "$STATE_FILE"

# A zero-length existing state is also not permission to copy a legacy node.
: >"$STATE_FILE"
: >"$CALLS"
if run_worker; then
  echo 'empty existing identity must require recovery' >&2
  exit 1
fi
[ ! -s "$STATE_FILE" ]
[ ! -e "$READY_FILE" ]
! grep -Fxq 'init start' "$CALLS"

rm -rf "$STATE_DIR"
printf 'tmpfs %s tmpfs rw 0 0\n' "$DATA_ROOT" >"$MOUNTS"
: >"$CALLS"
run_worker
test ! -e "$STATE_FILE"
test ! -e "$READY_FILE"
grep -Fxq 'init stop' "$CALLS"

# Publication must not overwrite a state created after the absence check.
printf '/dev/mmcblk0p27 %s ext4 rw 0 0\n' "$DATA_ROOT" >"$MOUNTS"
: >"$CALLS"
if TEST_STATE_RACE=1 run_worker; then
  echo 'concurrent identity creation must hold migration' >&2
  exit 1
fi
grep -Fxq 'concurrent-authoritative-state' "$STATE_FILE"
[ ! -e "$READY_FILE" ]
[ -z "$(find "$STATE_DIR" -name '*.new.*' -print -quit)" ]
! grep -Fxq 'init start' "$CALLS"

# A duplicate worker must leave the active worker's readiness marker alone.
mkdir "$WORK_DIR/lock"
printf '%s\n' 'ready-owned-by-active-worker' >"$READY_FILE"
: >"$CALLS"
run_worker
grep -Fxq 'ready-owned-by-active-worker' "$READY_FILE"
[ ! -s "$CALLS" ]
rmdir "$WORK_DIR/lock"

echo 'tailscale state persistence test passed'
