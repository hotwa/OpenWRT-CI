#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$ROOT_DIR/files/usr/sbin/agent-runtime"
INIT="$ROOT_DIR/files/etc/init.d/agent-runtime"
RC_LINK="$ROOT_DIR/files/etc/rc.d/S91agent-runtime"
UV_STORAGE="$ROOT_DIR/files/etc/init.d/uv-storage"
MULTICA="$ROOT_DIR/files/etc/init.d/multica"
NODE_PROFILE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
UPDATE_PROFILE="$ROOT_DIR/files/etc/profile.d/30-agent-update-check.sh"

for path in "$MANAGER" "$INIT" "$UV_STORAGE" "$MULTICA" "$NODE_PROFILE" "$UPDATE_PROFILE"; do
  [ -f "$path" ] || { echo "missing $path"; exit 1; }
done
[ -e "$RC_LINK" ] || { echo "missing agent-runtime boot enablement"; exit 1; }
if [ -L "$RC_LINK" ]; then
  [ "$(readlink "$RC_LINK")" = '../init.d/agent-runtime' ] || {
    echo "agent-runtime boot enablement link target mismatch: $(readlink "$RC_LINK")"
    exit 1
  }
else
  SYMLINK_MODE="$(git -C "$ROOT_DIR" ls-files -s -- "files/etc/rc.d/S91agent-runtime" | awk '{print $1}')"
  [ "$SYMLINK_MODE" = "120000" ] || {
    echo "agent-runtime boot enablement is not recorded as a git symlink"
    exit 1
  }
  [ "$(cat "$RC_LINK")" = '../init.d/agent-runtime' ] || {
    echo "agent-runtime boot enablement placeholder does not target ../init.d/agent-runtime"
    exit 1
  }
fi

sh -n "$MANAGER"
sh -n "$INIT"
sh -n "$UV_STORAGE"
sh -n "$MULTICA"

grep -q 'START=91' "$INIT"
grep -q 'agent-runtime reconcile --json' "$INIT"
grep -q 'generations' "$MANAGER"
grep -q 'quarantine' "$MANAGER"
grep -q 'operations' "$MANAGER"
grep -q 'flock -n 9' "$MANAGER"
grep -q 'usign -V' "$MANAGER"
grep -q 'archive_is_safe' "$MANAGER"
grep -q 'links_are_safe' "$MANAGER"
grep -q 'verify_critical_hashes' "$MANAGER"
grep -q 'minimum_space_bytes' "$MANAGER"
grep -q 'runtime_contract.node_abi' "$MANAGER"
grep -q 'free_space_kb' "$MANAGER"
grep -q '"components"' "$MANAGER"
grep -q '"health"' "$MANAGER"

# The public CLI must always produce one valid-shaped JSON envelope and reject
# unbounded arguments before it touches a runtime path.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/data"
: >"$TMP_ROOT/mounts"
status_json="$(AGENT_RUNTIME_DATA_ROOT="$TMP_ROOT/data" \
  AGENT_RUNTIME_MOUNTS_FILE="$TMP_ROOT/mounts" \
  AGENT_RUNTIME_BASELINE="$TMP_ROOT/baseline" \
  sh "$MANAGER" status --json)"
printf '%s' "$status_json" | grep -q '"ok":true'
printf '%s' "$status_json" | grep -q '"operation_id":null'
printf '%s' "$status_json" | grep -q '"components":{}'
if sh "$MANAGER" status --json unexpected >/dev/null 2>&1; then
  echo "agent-runtime accepted an unbounded argument"
  exit 1
fi
grep -q 'newer-compatible-wins' "$MANAGER"
grep -q 'legacy_compatible' "$MANAGER"
grep -q 'runtime_health' "$MANAGER"
grep -q 'agent-runtime-pi-plan-mode.ts' "$MANAGER"
grep -q "import hermes_cli.main" "$MANAGER"
grep -q 'OPENTUI_LIBC=musl' "$NODE_PROFILE"
grep -q 'OPENTUI_LIBC=musl' "$MULTICA"
grep -q 'agent-runtime upgrade' "$UPDATE_PROFILE"
if grep -Eq 'npm i -g|hermes update' "$UPDATE_PROFILE"; then
  echo "login banner still advertises mutable package upgrades"
  exit 1
fi
if grep -Eq 'mkdir -p.*DATA_ROOT/node|DATA_ROOT/node/bin[[:space:]\\]*\\\\' "$UV_STORAGE"; then
  echo "uv-storage still creates mutable /data/node/bin"
  exit 1
fi
grep -q '/data/agent-runtime/current' "$MULTICA"

for cmd in status check upgrade rollback list verify reconcile gc; do
  grep -q "$cmd" "$MANAGER" || { echo "missing command $cmd"; exit 1; }
done
grep -q 'operation_id' "$MANAGER"
grep -q 'signature_failed' "$MANAGER"
grep -q 'insufficient_space' "$MANAGER"
grep -q 'health_failed' "$MANAGER"

echo "agent runtime manager fixture tests passed"
