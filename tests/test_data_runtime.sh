#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="$ROOT_DIR/files/etc/init.d/data-runtime"
POLICY="$ROOT_DIR/files/etc/data-runtime.env"
PROFILE="$ROOT_DIR/files/etc/profile.d/99-data-runtime.sh"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/99-enable-data-runtime"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

test -x "$SERVICE"
test -f "$POLICY"
test -f "$PROFILE"
test -x "$DEFAULTS"
sh -n "$SERVICE"
sh -n "$PROFILE"
sh -n "$DEFAULTS"
grep -Fq '/proc/mounts' "$SERVICE"
grep -Fq 'data_write_probe' "$SERVICE"
grep -Fq 'wc -c' "$SERVICE"
grep -Fq 'DATA_RUNTIME_OVERLAY_MIN_KIB=51200' "$POLICY"
grep -Fq '/etc/init.d/data-runtime enable' "$DEFAULTS"
if grep -Eiq 'swapon|mmcblk.*swap|/etc/config/fstab' "$SERVICE" "$DEFAULTS"; then
	echo 'data runtime must not enable eMMC swap' >&2
	exit 1
fi

run_service() {
	local case_root="$1"
	shift
	env DATA_RUNTIME_DATA_ROOT="$case_root/data" \
		DATA_RUNTIME_OVERLAY_ROOT="$case_root/overlay" \
		DATA_RUNTIME_FALLBACK_ROOT="$case_root/root" \
		DATA_RUNTIME_EMERGENCY_ROOT="$case_root/emergency" \
		DATA_RUNTIME_RUN_DIR="$case_root/run" \
		DATA_RUNTIME_POLICY_FILE="$case_root/policy" \
		DATA_RUNTIME_MOUNTS_FILE="$case_root/mounts" \
		"$@" sh -c '. "$1"; start' sh "$SERVICE"
}

make_case() {
	local case_root="$1"
	mkdir -p "$case_root/data" "$case_root/overlay" "$case_root/run"
	cp "$POLICY" "$case_root/policy"
	: >"$case_root/mounts"
}

# A real block mount that accepts a one-byte probe uses persistent storage.
CASE_PERSISTENT="$TMP_ROOT/persistent"
make_case "$CASE_PERSISTENT"
printf '%s\n' "/dev/mmcblk0p27 $CASE_PERSISTENT/data ext4 rw 0 0" >"$CASE_PERSISTENT/mounts"
run_service "$CASE_PERSISTENT"
grep -Fxq 'state=persistent' "$CASE_PERSISTENT/run/data-runtime.status"
grep -Fxq "root=$CASE_PERSISTENT/data" "$CASE_PERSISTENT/run/data-runtime.status"
grep -Fxq "PNPM_HOME=$CASE_PERSISTENT/data/cache/pnpm" "$CASE_PERSISTENT/run/data-runtime.env"
grep -Fxq "UV_CACHE_DIR=$CASE_PERSISTENT/data/cache/uv" "$CASE_PERSISTENT/run/data-runtime.env"
grep -Fxq "UV_TOOL_DIR=$CASE_PERSISTENT/data/uv/tools" "$CASE_PERSISTENT/run/data-runtime.env"
grep -Fxq "PI_HOME=$CASE_PERSISTENT/data/pi" "$CASE_PERSISTENT/run/data-runtime.env"

# A bare or overlay /data directory is not accepted; >= 50 MiB selects the
# bounded overlay fallback rather than silently treating it as persistent.
CASE_FALLBACK="$TMP_ROOT/fallback"
make_case "$CASE_FALLBACK"
run_service "$CASE_FALLBACK"
grep -Fxq 'state=fallback' "$CASE_FALLBACK/run/data-runtime.status"
	grep -Fxq "DATA_RUNTIME_ROOT=$CASE_FALLBACK/root" "$CASE_FALLBACK/run/data-runtime.env"
grep -Fxq "NPM_CONFIG_CACHE=$CASE_FALLBACK/root/.npm" "$CASE_FALLBACK/run/data-runtime.env"
grep -Fxq "PNPM_HOME=$CASE_FALLBACK/root/.cache/pnpm" "$CASE_FALLBACK/run/data-runtime.env"
grep -Fxq "UV_TOOL_DIR=$CASE_FALLBACK/root/.local/share/uv/tools" "$CASE_FALLBACK/run/data-runtime.env"

# An unavailable/low-space overlay must select RAM-backed emergency storage.
CASE_EMERGENCY="$TMP_ROOT/emergency"
make_case "$CASE_EMERGENCY"
rm -rf "$CASE_EMERGENCY/overlay"
run_service "$CASE_EMERGENCY"
grep -Fxq 'state=emergency' "$CASE_EMERGENCY/run/data-runtime.status"
grep -Fxq "DATA_RUNTIME_ROOT=$CASE_EMERGENCY/emergency" "$CASE_EMERGENCY/run/data-runtime.env"
if grep -Eq '^(NPM_CONFIG_CACHE|PNPM_STORE_DIR|UV_CACHE_DIR|XDG_CACHE_HOME)=' "$CASE_EMERGENCY/run/data-runtime.env"; then
	echo 'emergency mode must avoid cache directories' >&2
	exit 1
fi

# A non-/dev source is never trusted even when it names a writable directory.
CASE_BIND="$TMP_ROOT/bind"
make_case "$CASE_BIND"
printf '%s\n' "/overlay $CASE_BIND/data overlay rw 0 0" >"$CASE_BIND/mounts"
run_service "$CASE_BIND"
grep -Fxq 'state=fallback' "$CASE_BIND/run/data-runtime.status"

echo 'data runtime tests passed'
