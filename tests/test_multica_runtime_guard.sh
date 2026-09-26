#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/multica-runtime-guard"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
DATA="$WORK/data"
mkdir -p "$BIN" "$DATA"

cat >"$BIN/uci" <<'EOF'
#!/bin/sh
case "$3" in
  multica.main.enabled) echo 1 ;;
  multica.main.runtime_provider) echo opencode ;;
esac
EOF
cat >"$BIN/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat >"$BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*"
EOF
cat >"$BIN/multica-init" <<'EOF'
#!/bin/sh
printf 'restart\n' >>"${MULTICA_RESTART_LOG:?}"
EOF
cat >"$WORK/opencode" <<'EOF'
#!/bin/sh
[ "${OC_VERSION_RC:-0}" = 0 ] && exit 0
exit 1
EOF
chmod 0755 "$BIN"/* "$WORK/opencode"
: >"$WORK/release-url"
export PATH="$BIN:$PATH"
export MULTICA_DATA_DIR="$DATA"
export OC_WRAPPER="$WORK/opencode"
export OC_RELEASE_FILE="$WORK/release-url"
export MULTICA_INIT="$BIN/multica-init"
export MULTICA_RESTART_LOG="$WORK/restarts"
export GUARD_LOCK_FILE="$WORK/guard.lock"
export MAINTENANCE_LOCK_FILE="$WORK/maintenance.lock"

# Ordinary health checks are not serialized behind the mutation lock.
OC_VERSION_RC=0 sh "$SCRIPT"
[ "$(cat "$DATA/.opencode_ok_count")" = 1 ]
[ ! -e "$MAINTENANCE_LOCK_FILE" ]

# A guard action defers cleanly if the shared mutation lock is held.
printf '2\n' >"$DATA/.opencode_fail_count"
flock -n "$MAINTENANCE_LOCK_FILE" -c 'sleep 1' &
holder=$!
sleep 0.1
OC_VERSION_RC=1 sh "$SCRIPT" >"$WORK/deferred.log" 2>&1
grep -Fq 'fallback action deferred because maintenance is active' "$WORK/deferred.log"
[ -x "$WORK/opencode" ]
[ ! -e "$DATA/.runtime_fallback_to_pi" ]
wait "$holder"

# The next scheduled guard can perform the action; it does not get stranded by
# a stale mkdir lock after the former owner exits.
OC_VERSION_RC=1 sh "$SCRIPT" >"$WORK/fallback.log" 2>&1
[ -f "$DATA/.runtime_fallback_to_pi" ]
[ ! -x "$WORK/opencode" ]
[ "$(wc -l <"$MULTICA_RESTART_LOG")" -eq 1 ]

echo "multica runtime guard lock tests passed"
