#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$ROOT_DIR/files/usr/sbin/agent-runtime"
INIT="$ROOT_DIR/files/etc/init.d/agent-runtime"
MULTICA="$ROOT_DIR/files/etc/init.d/multica"
DATA_MOUNT="$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
NODE_PROFILE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
UPDATE_PROFILE="$ROOT_DIR/files/etc/profile.d/30-agent-update-check.sh"

fail() { echo "agent runtime manager: $*" >&2; exit 1; }
for path in "$MANAGER" "$INIT" "$MULTICA" "$DATA_MOUNT" "$NODE_PROFILE" "$UPDATE_PROFILE"; do
  [ -f "$path" ] || fail "missing $path"
done
sh -n "$MANAGER"
sh -n "$INIT"
sh -n "$MULTICA"
sh -n "$DATA_MOUNT"

grep -Fq 'START=91' "$INIT" || fail "runtime reconcile boot order changed"
grep -Fq 'agent-runtime reconcile --json' "$INIT" || fail "runtime reconcile missing"
for term in 'generations' 'quarantine' 'flock -n 9' 'usign -V' 'archive_is_safe' 'links_are_safe' 'verify_critical_hashes' 'runtime_health'; do
  grep -Fq "$term" "$MANAGER" || fail "manager omits $term"
done
for command in pi cmdc multica; do
  grep -Fq "for command in pi cmdc multica" "$MANAGER" || fail "runtime health does not cover Pi, CommandCode and Multica"
done
if grep -Eqi 'hermes|opencode|uv' "$MANAGER" "$INIT" "$MULTICA" "$NODE_PROFILE" "$UPDATE_PROFILE"; then
  fail "runtime scripts still reference a retired CLI or Python runtime"
fi

for directory in '$DATA_ROOT/pi/agent' '$DATA_ROOT/commandcode' '$DATA_ROOT/multica/workspaces' '$DATA_ROOT/smb'; do
  grep -Fq "$directory" "$DATA_MOUNT" || fail "data mount bootstrap omits $directory"
done
grep -Fq 'link_directory "$DATA_ROOT/pi" "$ROOT_HOME/.pi" pi' "$DATA_MOUNT" || fail "Pi state is not persistent"
grep -Fq 'link_directory "$DATA_ROOT/commandcode" "$ROOT_HOME/.commandcode" commandcode' "$DATA_MOUNT" || fail "CommandCode state is not persistent"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/data"
: >"$TMP_ROOT/mounts"
status_json="$(AGENT_RUNTIME_DATA_ROOT="$TMP_ROOT/data" AGENT_RUNTIME_MOUNTS_FILE="$TMP_ROOT/mounts" AGENT_RUNTIME_BASELINE="$TMP_ROOT/baseline" sh "$MANAGER" status --json)"
printf '%s' "$status_json" | grep -Fq '"ok":true' || fail "status JSON envelope is invalid"
if sh "$MANAGER" status --json unexpected >/dev/null 2>&1; then
  fail "manager accepted an unbounded argument"
fi

echo "agent runtime manager fixture tests passed"
