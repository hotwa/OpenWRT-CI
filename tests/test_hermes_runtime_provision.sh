#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/hermes-runtime"
PROVISIONER="$ROOT_DIR/files/usr/sbin/hermes-runtime-provision"
UCI_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/97-enable-hermes-runtime"
UV_STORAGE="$ROOT_DIR/files/etc/init.d/uv-storage"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"

for path in "$INIT_SCRIPT" "$PROVISIONER" "$UCI_DEFAULTS" "$UV_STORAGE" "$FETCH_SCRIPT"; do
  [ -f "$path" ] || { echo "missing $path"; exit 1; }
done

# The provisioner needs the /data caches and prefix published by uv-storage.
INIT_START="$(grep -oP '^START=\K[0-9]+' "$INIT_SCRIPT")"
UV_START="$(grep -oP '^START=\K[0-9]+' "$UV_STORAGE")"
[ -n "$INIT_START" ] && [ -n "$UV_START" ] || {
  echo "missing START levels"
  exit 1
}
[ "$INIT_START" -gt "$UV_START" ] || {
  echo "hermes-runtime must start after uv-storage publishes /tmp/uv-env.sh"
  exit 1
}

grep -q 'data_is_ready' "$INIT_SCRIPT" || {
  echo "hermes-runtime does not gate on a writable /data mount"
  exit 1
}

grep -q 'start-stop-daemon -S -b' "$INIT_SCRIPT" || {
  echo "hermes-runtime must not block boot while it downloads a runtime"
  exit 1
}

grep -q 'install -g --prefix' "$PROVISIONER" || {
  echo "provisioner does not install into the writable global prefix"
  exit 1
}

grep -q 'wait_for_default_route' "$PROVISIONER" || {
  echo "provisioner does not wait for WAN before reaching for npm/PyPI"
  exit 1
}

grep -q 'PATH="/opt/node/bin:/data/node/bin:/usr/bin:/bin"' "$PROVISIONER" || {
  echo "provisioner must export the Node.js PATH itself; procd does not load /etc/profile.d"
  exit 1
}

grep -q 'import hermes_cli.main' "$PROVISIONER" || {
  echo "provisioner does not prove the rebuilt venv can execute the hermes entry module"
  exit 1
}

grep -q 'hermes-runtime enable' "$UCI_DEFAULTS" || {
  echo "uci-defaults does not enable the hermes runtime service"
  exit 1
}

grep -q 'export NPM_CONFIG_PREFIX=$DATA_ROOT/node' "$UV_STORAGE" || {
  echo "uv-storage does not publish a writable npm global prefix"
  exit 1
}

grep -q 'HERMES_NPM_VERSION=' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not emit the pinned hermes version"
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Behavior 1: an already usable runtime must be left alone without touching npm.
READY_ROOT="$WORK_DIR/ready-data"
READY_VENV="$READY_ROOT/node/lib/node_modules/hermes-agent/runtime/hermes-agent/venv/bin"
mkdir -p "$READY_VENV"
printf '#!/bin/sh\nexit 0\n' >"$READY_VENV/hermes"
printf '#!/bin/sh\nexit 0\n' >"$READY_VENV/python"
chmod 0755 "$READY_VENV/hermes" "$READY_VENV/python"
: >"$READY_ROOT/log"
HERMES_DATA_ROOT="$READY_ROOT" HERMES_RUNTIME_LOG="$READY_ROOT/log" \
  sh "$PROVISIONER" || {
  echo "provisioner failed on an already provisioned runtime"
  exit 1
}
[ -s "$READY_ROOT/log" ] && {
  echo "provisioner logged work for an already provisioned runtime"
  exit 1
}

# Behavior 2: an unusable policy must fail loudly instead of installing a
# floating version from the registry.
BROKEN_ROOT="$WORK_DIR/broken-data"
mkdir -p "$BROKEN_ROOT"
: >"$BROKEN_ROOT/log"
if HERMES_DATA_ROOT="$BROKEN_ROOT" HERMES_RUNTIME_LOG="$BROKEN_ROOT/log" \
  HERMES_WAN_ATTEMPTS=1 HERMES_WAN_INTERVAL=0 \
  HERMES_RUNTIME_POLICY="$WORK_DIR/absent.env" sh "$PROVISIONER"; then
  echo "provisioner accepted a missing version policy"
  exit 1
fi
grep -q 'pinned hermes-agent policy is unusable' "$BROKEN_ROOT/log" || {
  echo "provisioner did not report why it refused to install"
  exit 1
}

echo "hermes device-side runtime provisioning tests passed"
