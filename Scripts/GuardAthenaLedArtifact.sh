#!/bin/sh
set -eu

die() {
	echo "ERROR: $*" >&2
	exit 1
}

[ "$#" -eq 2 ] || die "usage: $0 CONFIG TARGETS_DIR"

config=$1
targets_dir=$2
device='jdcloud_re-cs-02'

[ -f "$config" ] || die "missing build config: $config"

if ! grep -q "^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_${device}=y$" "$config"; then
	echo "Athena LED artifact guard: $device is not selected; skipping"
	exit 0
fi

[ -d "$targets_dir" ] || die "missing targets directory: $targets_dir"

manifest=$(find "$targets_dir" -type f -name "*${device}*.manifest" -print -quit)
[ -n "$manifest" ] || die "missing $device firmware manifest"

grep -q '^athena-led - ' "$manifest" || die "$device image is missing athena-led core"
grep -q '^luci-app-athena-led - ' "$manifest" || die "$device image is missing luci-app-athena-led"

echo "Athena LED artifact guard passed: $manifest"
