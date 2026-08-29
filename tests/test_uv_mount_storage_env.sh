#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT_DIR/files/etc/profile.d/uv.sh"
NODE_PROFILE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
INIT="$ROOT_DIR/files/etc/init.d/uv-storage"
RC_LINK="$ROOT_DIR/files/etc/rc.d/S90uv-storage"
SMOKE="$ROOT_DIR/files/usr/bin/uv-runtime-smoke"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

[ -f "$PROFILE" ] || { echo "missing uv profile script"; exit 1; }
[ -f "$NODE_PROFILE" ] || { echo "missing node profile script"; exit 1; }
[ -f "$INIT" ] || { echo "missing uv init script"; exit 1; }
[ -e "$RC_LINK" ] || { echo "missing uv init enablement entry"; exit 1; }

if [ -L "$RC_LINK" ]; then
	[ "$(readlink "$RC_LINK")" = "../init.d/uv-storage" ] || {
		echo "uv init enablement does not target ../init.d/uv-storage"
		exit 1
	}
else
	SYMLINK_MODE="$(git -C "$ROOT_DIR" ls-files -s -- "files/etc/rc.d/S90uv-storage" | awk '{print $1}')"
	[ "$SYMLINK_MODE" = "120000" ] || {
		echo "uv init enablement is not recorded as a git symlink"
		exit 1
	}
	[ "$(cat "$RC_LINK")" = "../init.d/uv-storage" ] || {
		echo "uv init enablement placeholder does not target ../init.d/uv-storage"
		exit 1
	}
fi

[ -x "$INIT" ] || { echo "uv init script is not executable"; exit 1; }
bash -n "$INIT"
grep -q '/tmp/uv-env.sh' "$PROFILE"
grep -q '/tmp/uv-env.sh' "$NODE_PROFILE"
grep -q 'UV_PYTHON_INSTALL_MIRROR=file:///opt/uv/python-mirror' "$PROFILE" || {
	echo "uv profile script does not export the immutable Python mirror"
	exit 1
}
if grep -Eq '/mnt/mmc|for path in /mnt|echo "/opt/uv"' "$INIT"; then
	echo "uv storage still selects an alternate mutable storage root"
	exit 1
fi

# Without a real /data mount, no environment or mutable directory may be made.
NO_MOUNT="$TMP_ROOT/no-mount"
mkdir -p "$NO_MOUNT"
: >"$NO_MOUNT/mounts"
if UV_STORAGE_DATA_ROOT="$NO_MOUNT/data" \
	UV_STORAGE_MOUNTS_FILE="$NO_MOUNT/mounts" \
	UV_STORAGE_RUNTIME_ENV="$NO_MOUNT/uv-env.sh" \
	sh -c '. "$1"; start' sh "$INIT"; then
	echo "uv-storage did not fail closed without /data"
	exit 1
fi
[ ! -e "$NO_MOUNT/data" ] && [ ! -e "$NO_MOUNT/uv-env.sh" ] || {
	echo "uv-storage wrote mutable state without /data"
	exit 1
}

# A verified writable mount publishes one environment for interactive and
# non-interactive consumers.
READY="$TMP_ROOT/ready"
mkdir -p "$READY/data"
printf '%s %s ext4 rw 0 0\n' /dev/mmcblk0p11 "$READY/data" >"$READY/mounts"
UV_STORAGE_DATA_ROOT="$READY/data" \
	UV_STORAGE_MOUNTS_FILE="$READY/mounts" \
	UV_STORAGE_RUNTIME_ENV="$READY/uv-env.sh" \
	sh -c '. "$1"; start' sh "$INIT"

for expected in \
	"UV_CACHE_DIR=$READY/data/uv_cache" \
	"UV_PYTHON_INSTALL_DIR=$READY/data/uv/python" \
	"PNPM_STORE_DIR=$READY/data/pnpm/store" \
	"NPM_CONFIG_CACHE=$READY/data/npm/cache" \
	"XDG_CACHE_HOME=$READY/data/cache"; do
	grep -Fq "$expected" "$READY/uv-env.sh" || {
		echo "runtime environment missing: $expected"
		exit 1
	}
done

[ -f "$SMOKE" ] || { echo "missing uv runtime smoke helper"; exit 1; }
grep -q 'python3 -m venv /tmp/uv-smoke-venv' "$SMOKE"
grep -q '. /tmp/uv-env.sh' "$SMOKE"
grep -q '/opt/uv/python-mirror/manifest.txt' "$SMOKE" || {
	echo "uv runtime smoke helper must take its interpreter series from the offline mirror manifest"
	exit 1
}

echo "uv mount-aware storage fixture tests passed"
