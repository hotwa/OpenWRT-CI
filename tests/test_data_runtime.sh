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
grep -Fq '/proc/self/mountinfo' "$SERVICE"
grep -Fq 'data_write_probe' "$SERVICE"
grep -Fq 'wc -c' "$SERVICE"
grep -Fq '/var/run/root-overlay.status' "$PROFILE"
grep -Fq '[ -t 1 ]' "$PROFILE"
grep -Fq 'id -u' "$PROFILE"
grep -Fq '[ ! -L "$ROOT_OVERLAY_STATUS_FILE" ]' "$PROFILE"
grep -Fq 'Changes under /etc and /root may be lost after reboot.' "$PROFILE"
if grep -Fq '. "$ROOT_OVERLAY_STATUS_FILE"' "$PROFILE"; then
	echo 'root overlay status must never be sourced by the login profile' >&2
	exit 1
fi
grep -Fq 'DATA_RUNTIME_OVERLAY_MIN_KIB=51200' "$POLICY"
grep -Fq '/etc/init.d/data-runtime enable' "$DEFAULTS"
if grep -Eiq 'swapon|mmcblk.*swap|/etc/config/fstab' "$SERVICE" "$DEFAULTS"; then
	echo 'data runtime must not enable eMMC swap' >&2
	exit 1
fi
if grep -Eiq '(^|[[:space:]])(reboot|sysupgrade|mkfs\.|mount[[:space:]]+-o|umount)([[:space:]]|$)' "$SERVICE"; then
	echo 'root overlay health reporting must not mutate storage or restart the device' >&2
	exit 1
fi
if grep -Eq 'rm[[:space:]]+-rf.*(overlay|DATA_ROOT|ROOT_OVERLAY)' "$SERVICE"; then
	echo 'root overlay health reporting must not clean overlay or data directories' >&2
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
		DATA_RUNTIME_ROOT_MOUNTINFO_FILE="$case_root/mountinfo" \
		DATA_RUNTIME_ROOT_OVERLAY_PERSIST_DIR="$case_root/data/.root-overlay-health" \
		"$@" sh -c '. "$1"; start' sh "$SERVICE"
}

make_case() {
	local case_root="$1"
	mkdir -p "$case_root/data" "$case_root/overlay" "$case_root/run"
	cp "$POLICY" "$case_root/policy"
	: >"$case_root/mounts"
	printf '%s\n' '36 24 0:31 / / rw,relatime - overlay overlayfs:/overlay rw,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work' >"$case_root/mountinfo"
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
grep -Fxq 'state=healthy' "$CASE_PERSISTENT/run/root-overlay.status"
grep -Fxq 'reason=persistent-overlay' "$CASE_PERSISTENT/run/root-overlay.status"
[ "$(stat -c %a "$CASE_PERSISTENT/run/root-overlay.status")" = 644 ]
test ! -e "$CASE_PERSISTENT/data/.root-overlay-health"

# A RAM upperdir is reported without changing the persistent runtime choice.
# The persistent alert is additive and never removes an operator sentinel.
CASE_RAM_OVERLAY="$TMP_ROOT/ram-overlay"
make_case "$CASE_RAM_OVERLAY"
printf '%s\n' "/dev/mmcblk0p27 $CASE_RAM_OVERLAY/data ext4 rw 0 0" >"$CASE_RAM_OVERLAY/mounts"
printf '%s\n' '36 24 0:31 / / rw,relatime - overlay overlayfs:/tmp/root rw,lowerdir=/,upperdir=/tmp/root/upper,workdir=/tmp/root/work' >"$CASE_RAM_OVERLAY/mountinfo"
mkdir -m 0700 "$CASE_RAM_OVERLAY/data/.root-overlay-health"
printf '%s\n' keep >"$CASE_RAM_OVERLAY/data/.root-overlay-health/operator-sentinel"
run_service "$CASE_RAM_OVERLAY"
grep -Fxq 'state=persistent' "$CASE_RAM_OVERLAY/run/data-runtime.status"
grep -Fxq 'state=degraded' "$CASE_RAM_OVERLAY/run/root-overlay.status"
grep -Fxq 'reason=ram-overlay' "$CASE_RAM_OVERLAY/run/root-overlay.status"
grep -Fxq 'root_upper=/tmp/root/upper' "$CASE_RAM_OVERLAY/run/root-overlay.status"
grep -Fxq 'state=degraded' "$CASE_RAM_OVERLAY/data/.root-overlay-health/last-degraded.status"
grep -Fxq 'reason=ram-overlay' "$CASE_RAM_OVERLAY/data/.root-overlay-health/last-degraded.status"
[ "$(stat -c %a "$CASE_RAM_OVERLAY/data/.root-overlay-health")" = 700 ]
[ "$(stat -c %a "$CASE_RAM_OVERLAY/data/.root-overlay-health/last-degraded.status")" = 600 ]
grep -Fxq keep "$CASE_RAM_OVERLAY/data/.root-overlay-health/operator-sentinel"

# An unexpected overlay upperdir is degraded.
CASE_UNEXPECTED_UPPER="$TMP_ROOT/unexpected-upper"
make_case "$CASE_UNEXPECTED_UPPER"
printf '%s\n' '36 24 0:31 / / rw,relatime - overlay overlayfs:/other rw,lowerdir=/,upperdir=/other/upper,workdir=/other/work' >"$CASE_UNEXPECTED_UPPER/mountinfo"
run_service "$CASE_UNEXPECTED_UPPER"
grep -Fxq 'state=degraded' "$CASE_UNEXPECTED_UPPER/run/root-overlay.status"
grep -Fxq 'reason=unexpected-overlay-upper' "$CASE_UNEXPECTED_UPPER/run/root-overlay.status"

# Known persistent root filesystems mounted read-write are healthy without an
# overlay upperdir. Cover both a block filesystem and raw-flash UBIFS.
CASE_EXT4_RW="$TMP_ROOT/ext4-rw"
make_case "$CASE_EXT4_RW"
printf '%s\n' '24 1 179:18 / / rw,relatime - ext4 /dev/mmcblk0p18 rw,errors=remount-ro' >"$CASE_EXT4_RW/mountinfo"
run_service "$CASE_EXT4_RW"
grep -Fxq 'state=healthy' "$CASE_EXT4_RW/run/root-overlay.status"
grep -Fxq 'reason=persistent-root' "$CASE_EXT4_RW/run/root-overlay.status"
grep -Fxq 'root_fstype=ext4' "$CASE_EXT4_RW/run/root-overlay.status"
grep -Fxq 'root_mount_options=rw,relatime' "$CASE_EXT4_RW/run/root-overlay.status"
grep -Fxq 'root_upper=not-applicable' "$CASE_EXT4_RW/run/root-overlay.status"

CASE_UBIFS_RW="$TMP_ROOT/ubifs-rw"
make_case "$CASE_UBIFS_RW"
printf '%s\n' '24 1 0:21 / / rw,relatime - ubifs ubi0:rootfs rw,assert=read-only' >"$CASE_UBIFS_RW/mountinfo"
run_service "$CASE_UBIFS_RW"
grep -Fxq 'state=healthy' "$CASE_UBIFS_RW/run/root-overlay.status"
grep -Fxq 'reason=persistent-root' "$CASE_UBIFS_RW/run/root-overlay.status"
grep -Fxq 'root_fstype=ubifs' "$CASE_UBIFS_RW/run/root-overlay.status"
grep -Fxq 'root_upper=not-applicable' "$CASE_UBIFS_RW/run/root-overlay.status"

# A persistent filesystem mounted read-only remains degraded.
CASE_EXT4_RO="$TMP_ROOT/ext4-ro"
make_case "$CASE_EXT4_RO"
printf '%s\n' '24 1 179:18 / / ro,relatime - ext4 /dev/mmcblk0p18 ro,errors=remount-ro' >"$CASE_EXT4_RO/mountinfo"
run_service "$CASE_EXT4_RO"
grep -Fxq 'state=degraded' "$CASE_EXT4_RO/run/root-overlay.status"
grep -Fxq 'reason=root-read-only' "$CASE_EXT4_RO/run/root-overlay.status"
grep -Fxq 'root_mount_options=ro,relatime' "$CASE_EXT4_RO/run/root-overlay.status"

# Read-only image roots remain degraded when no writable overlay is active.
CASE_NON_OVERLAY="$TMP_ROOT/non-overlay"
make_case "$CASE_NON_OVERLAY"
printf '%s\n' '24 1 179:18 / / ro,relatime - squashfs /dev/root ro,errors=continue' >"$CASE_NON_OVERLAY/mountinfo"
run_service "$CASE_NON_OVERLAY"
grep -Fxq 'state=degraded' "$CASE_NON_OVERLAY/run/root-overlay.status"
grep -Fxq 'reason=read-only-root' "$CASE_NON_OVERLAY/run/root-overlay.status"

# Missing mountinfo remains an explicit degraded state but never blocks the
# existing runtime selection.
CASE_NO_MOUNTINFO="$TMP_ROOT/no-mountinfo"
make_case "$CASE_NO_MOUNTINFO"
rm -f "$CASE_NO_MOUNTINFO/mountinfo"
run_service "$CASE_NO_MOUNTINFO"
grep -Fxq 'state=fallback' "$CASE_NO_MOUNTINFO/run/data-runtime.status"
grep -Fxq 'state=degraded' "$CASE_NO_MOUNTINFO/run/root-overlay.status"
grep -Fxq 'reason=mountinfo-unreadable' "$CASE_NO_MOUNTINFO/run/root-overlay.status"

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
printf '%s\n' '36 24 0:31 / / rw,relatime - overlay overlayfs:/tmp/root rw,lowerdir=/,upperdir=/tmp/root/upper,workdir=/tmp/root/work' >"$CASE_BIND/mountinfo"
run_service "$CASE_BIND"
grep -Fxq 'state=fallback' "$CASE_BIND/run/data-runtime.status"
grep -Fxq 'state=degraded' "$CASE_BIND/run/root-overlay.status"
test ! -e "$CASE_BIND/data/.root-overlay-health"

# Refuse both a symlinked persistent alert directory and a symlinked marker.
# Reporting still succeeds through /var/run and never changes runtime state.
CASE_ALERT_SYMLINK="$TMP_ROOT/alert-symlink"
make_case "$CASE_ALERT_SYMLINK"
printf '%s\n' "/dev/mmcblk0p27 $CASE_ALERT_SYMLINK/data ext4 rw 0 0" >"$CASE_ALERT_SYMLINK/mounts"
printf '%s\n' '36 24 0:31 / / rw,relatime - overlay overlayfs:/tmp/root rw,lowerdir=/,upperdir=/tmp/root/upper,workdir=/tmp/root/work' >"$CASE_ALERT_SYMLINK/mountinfo"
mkdir "$CASE_ALERT_SYMLINK/outside"
ln -s "$CASE_ALERT_SYMLINK/outside" "$CASE_ALERT_SYMLINK/data/.root-overlay-health"
run_service "$CASE_ALERT_SYMLINK"
grep -Fxq 'state=persistent' "$CASE_ALERT_SYMLINK/run/data-runtime.status"
grep -Fxq 'state=degraded' "$CASE_ALERT_SYMLINK/run/root-overlay.status"
test ! -e "$CASE_ALERT_SYMLINK/outside/last-degraded.status"

CASE_MARKER_SYMLINK="$TMP_ROOT/marker-symlink"
make_case "$CASE_MARKER_SYMLINK"
printf '%s\n' "/dev/mmcblk0p27 $CASE_MARKER_SYMLINK/data ext4 rw 0 0" >"$CASE_MARKER_SYMLINK/mounts"
printf '%s\n' '36 24 0:31 / / rw,relatime - overlay overlayfs:/tmp/root rw,lowerdir=/,upperdir=/tmp/root/upper,workdir=/tmp/root/work' >"$CASE_MARKER_SYMLINK/mountinfo"
mkdir -m 0700 "$CASE_MARKER_SYMLINK/data/.root-overlay-health"
printf '%s\n' untouched >"$CASE_MARKER_SYMLINK/outside-marker"
ln -s "$CASE_MARKER_SYMLINK/outside-marker" "$CASE_MARKER_SYMLINK/data/.root-overlay-health/last-degraded.status"
run_service "$CASE_MARKER_SYMLINK"
grep -Fxq untouched "$CASE_MARKER_SYMLINK/outside-marker"

# Even an unwritable/invalid volatile status destination is diagnostic-only.
CASE_STATUS_FAILOPEN="$TMP_ROOT/status-failopen"
make_case "$CASE_STATUS_FAILOPEN"
printf '%s\n' blocker >"$CASE_STATUS_FAILOPEN/not-a-directory"
run_service "$CASE_STATUS_FAILOPEN" \
	DATA_RUNTIME_ROOT_OVERLAY_STATUS_FILE="$CASE_STATUS_FAILOPEN/not-a-directory/status"
grep -Fxq 'state=fallback' "$CASE_STATUS_FAILOPEN/run/data-runtime.status"

echo 'data runtime tests passed'
