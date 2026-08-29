#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/hermes-runtime"
PROVISIONER="$ROOT_DIR/files/usr/sbin/hermes-runtime-provision"
UCI_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/97-enable-hermes-runtime"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"

for path in "$INIT_SCRIPT" "$PROVISIONER" "$UCI_DEFAULTS" "$FETCH_SCRIPT"; do
  [ -f "$path" ] || { echo "missing $path"; exit 1; }
done
sh -n "$INIT_SCRIPT"
sh -n "$PROVISIONER"

INIT_START="$(grep -oP '^START=\K[0-9]+' "$INIT_SCRIPT")"
[ -n "$INIT_START" ] && [ "$INIT_START" -gt 91 ] || {
  echo "hermes-runtime must start after the runtime reconcile service"
  exit 1
}
grep -q 'start-stop-daemon -S -b' "$INIT_SCRIPT" || {
  echo "hermes-runtime must not block boot"; exit 1;
}
grep -q 'core-offline' "$PROVISIONER" || {
  echo "provisioner is not enforcing the offline Core policy"; exit 1;
}
grep -q 'import hermes_cli.main' "$PROVISIONER" || {
  echo "provisioner does not import-check Hermes Core"; exit 1;
}
grep -q 'HERMES_RUNTIME_ROOT' "$PROVISIONER" || {
  echo "provisioner cannot coordinate an active runtime generation"; exit 1;
}
grep -q 'hermes-runtime enable' "$UCI_DEFAULTS" || {
  echo "uci-defaults does not enable the Hermes service"; exit 1;
}
grep -q 'HERMES_RUNTIME_MODE=core-offline' "$FETCH_SCRIPT" || {
  echo "firmware policy does not publish offline Hermes Core"; exit 1;
}

# The device service is intentionally incapable of reaching a registry or
# creating a mutable /data npm prefix.  Search executable lines only so prose
# cannot hide a reintroduced network provisioning command.
if awk '!/^[[:space:]]*#/' "$PROVISIONER" | grep -Eq '(^|[[:space:]])(npm|pnpm|uv|git|curl|wget)[[:space:]]'; then
  echo "offline Hermes provisioner still contains a network/install command"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ROOT="$WORK_DIR/opt/node/lib/node_modules/hermes-agent/runtime/hermes-agent"
mkdir -p "$ROOT/venv/bin" "$WORK_DIR/state"
printf 'lock\n' >"$ROOT/uv.lock"
printf '#!/bin/sh\n[ "$1" = "-c" ] && exit 0\nexit 0\n' >"$ROOT/venv/bin/python"
printf '#!/bin/sh\nexit 0\n' >"$ROOT/venv/bin/hermes"
chmod 0755 "$ROOT/venv/bin/python" "$ROOT/venv/bin/hermes"
cat >"$WORK_DIR/policy.env" <<EOF
HERMES_RUNTIME_MODE=core-offline
HERMES_NPM_VERSION=0.20.6
HERMES_PYTHON_SERIES=3.11
EOF
cat >"$WORK_DIR/hermes-core.json" <<EOF
{"core_root":"$ROOT"}
EOF
PROVISIONER_FIX="$WORK_DIR/hermes-runtime-provision"
# Keep the production allow-list strict while exercising the happy path in an
# unprivileged temporary fixture.
sed -e "s|/opt/node/lib/node_modules/hermes-agent/runtime/hermes-agent|$ROOT|g" \
  -e "s|/data/agent-runtime|$WORK_DIR/agent-runtime|g" \
  -e 's|/opt/\*|/tmp/\*|g' \
  "$PROVISIONER" >"$PROVISIONER_FIX"
chmod 0755 "$PROVISIONER_FIX"

# A data-less baseline is healthy and must make no network attempt.
HERMES_RUNTIME_ROOT="$ROOT" HERMES_RUNTIME_POLICY="$WORK_DIR/policy.env" \
  HERMES_RUNTIME_STATE="$WORK_DIR/state/status" HERMES_RUNTIME_LOG="$WORK_DIR/state/log" \
  sh "$PROVISIONER_FIX" >"$WORK_DIR/health.out" 2>&1 || { cat "$WORK_DIR/health.out"; cat "$WORK_DIR/state/log" 2>/dev/null || true; echo "offline baseline health check failed"; exit 1; }
grep -q '^ok ' "$WORK_DIR/state/status" || { echo "health coordinator did not publish success"; exit 1; }

# A verified active generation takes precedence over /opt without following an
# arbitrary link target.
ACTIVE_ROOT="$WORK_DIR/agent-runtime/generations/release-1/node/lib/node_modules/hermes-agent/runtime"
mkdir -p "$ACTIVE_ROOT"
cp -a "$ROOT" "$ACTIVE_ROOT/hermes-agent"
ln -s generations/release-1 "$WORK_DIR/agent-runtime/current"
HERMES_RUNTIME_POLICY="$WORK_DIR/policy.env" HERMES_AGENT_RUNTIME_ROOT="$WORK_DIR/agent-runtime" \
  HERMES_RUNTIME_STATE="$WORK_DIR/state/active-status" HERMES_RUNTIME_LOG="$WORK_DIR/state/active-log" \
  sh "$PROVISIONER_FIX" || { echo "active generation health check failed"; exit 1; }
grep -q "release-1/node" "$WORK_DIR/state/active-status" || { echo "active generation was not selected"; exit 1; }

# Metadata cannot redirect the service to an arbitrary path.
if HERMES_RUNTIME_ROOT=/tmp/not-hermes HERMES_RUNTIME_POLICY="$WORK_DIR/policy.env" \
  HERMES_RUNTIME_STATE="$WORK_DIR/state/bad-status" HERMES_RUNTIME_LOG="$WORK_DIR/state/bad-log" \
  sh "$PROVISIONER_FIX"; then
  echo "provisioner accepted an unsafe runtime root"
  exit 1
fi
grep -q 'unsafe' "$WORK_DIR/state/bad-status" || { echo "unsafe root was not reported"; exit 1; }

echo "hermes offline Core coordinator tests passed"
