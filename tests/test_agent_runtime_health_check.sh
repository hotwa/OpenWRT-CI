#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/agent-runtime-health-check"
INIT="$ROOT_DIR/files/etc/init.d/agent-runtime-health-check"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/95-agent-runtime-health-check"

for path in "$SCRIPT" "$INIT" "$DEFAULTS"; do
	[ -x "$path" ] || { echo "missing executable $path" >&2; exit 1; }
done
sh -n "$SCRIPT"
sh -n "$INIT"
grep -Fq 'START=96' "$INIT"
grep -Fq '/etc/init.d/agent-runtime-health-check enable' "$DEFAULTS"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/agent-runtime" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$RUNTIME_CALLS"
case "$1" in
	verify) printf '%s\n' "${VERIFY_JSON:-{\"ok\":true,\"code\":\"ok\"}}" ;;
	rollback) printf '%s\n' "${ROLLBACK_JSON:-{\"ok\":true,\"code\":\"ok\"}}" ;;
esac
EOF
chmod 0755 "$WORK_DIR/agent-runtime"

run_check() {
	RUNTIME_BIN="$WORK_DIR/agent-runtime" \
	STATUS_FILE="$WORK_DIR/status" \
	LOCK_FILE="$WORK_DIR/health.lock" \
	MAINTENANCE_LOCK_FILE="$WORK_DIR/maintenance.lock" \
	RUNTIME_CALLS="$WORK_DIR/calls" \
	"$SCRIPT"
}

run_check
grep -Fxq 'verify' "$WORK_DIR/calls"
grep -Fqx 'state=verified' "$WORK_DIR/status"
grep -Fqx 'code=ok' "$WORK_DIR/status"

: >"$WORK_DIR/calls"
VERIFY_JSON='{"ok":false,"code":"health_failed"}' run_check
grep -Fxq 'verify' "$WORK_DIR/calls"
grep -Fxq 'rollback' "$WORK_DIR/calls"
grep -Fqx 'state=rolled_back' "$WORK_DIR/status"

: >"$WORK_DIR/calls"
VERIFY_JSON='{"ok":false,"code":"no_data"}' run_check
[ "$(wc -l <"$WORK_DIR/calls")" -eq 1 ] || { echo 'transient /data unavailability attempted rollback' >&2; exit 1; }
grep -Fqx 'state=deferred' "$WORK_DIR/status"
grep -Fqx 'code=no_data' "$WORK_DIR/status"

: >"$WORK_DIR/calls"
VERIFY_JSON='{"ok":false,"code":"health_failed"}' \
ROLLBACK_JSON='{"ok":false,"code":"busy"}' run_check
grep -Fqx 'state=deferred' "$WORK_DIR/status"
grep -Fqx 'code=busy' "$WORK_DIR/status"

# Existing maintenance work owns the shared mutation lock: verification and
# rollback must defer rather than race a signed generation switch.
: >"$WORK_DIR/calls"
flock -n "$WORK_DIR/maintenance-held.lock" -c 'sleep 2' &
lock_holder=$!
sleep 0.1
RUNTIME_BIN="$WORK_DIR/agent-runtime" \
STATUS_FILE="$WORK_DIR/status" \
LOCK_FILE="$WORK_DIR/health-held.lock" \
MAINTENANCE_LOCK_FILE="$WORK_DIR/maintenance-held.lock" \
RUNTIME_CALLS="$WORK_DIR/calls" \
"$SCRIPT"
wait "$lock_holder"
[ ! -s "$WORK_DIR/calls" ] || { echo 'health checker ignored active maintenance lock' >&2; exit 1; }
grep -Fqx 'state=deferred' "$WORK_DIR/status"
grep -Fqx 'code=maintenance_busy' "$WORK_DIR/status"

: >"$WORK_DIR/calls"
if VERIFY_JSON='{"ok":false,"code":"health_failed"}' \
	ROLLBACK_JSON='{"ok":false,"code":"health_failed"}' run_check; then
	echo 'failed safe rollback returned success' >&2
	exit 1
fi
grep -Fqx 'state=rollback_failed' "$WORK_DIR/status"

# Never write command output or runtime details into the status file.
if grep -Eqi 'token|secret|https?://' "$WORK_DIR/status"; then
	echo 'runtime health status contains potentially sensitive output' >&2
	exit 1
fi

echo 'agent runtime health check tests passed'
