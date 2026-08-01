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
if [ -n "$manifest" ]; then
	grep -q '^athena-led - ' "$manifest" || die "$device image is missing athena-led core"
	grep -q '^luci-app-athena-led - ' "$manifest" || die "$device image is missing luci-app-athena-led"
	echo "Athena LED artifact guard passed: $manifest"
	exit 0
fi

topdir=$(CDPATH= cd -- "$targets_dir/../.." && pwd)
image_file="$topdir/target/linux/qualcommax/image/ipq60xx.mk"
image=$(find "$targets_dir" -type f -name "*${device}*" -print -quit)

[ -n "$image" ] || die "missing $device firmware image"
[ -f "$image_file" ] || die "missing $device image definition"

# VIKINGYFY/immortalwrt writes one target-level manifest even with per-device
# rootfs enabled. Its device package definition is the final image input.
device_block=$(sed -n "/^define Device\/${device}$/,/^endef$/p" "$image_file")
[ -n "$device_block" ] || die "missing $device image definition block"

core_count=$(printf '%s\n' "$device_block" | awk '{ for (i = 1; i <= NF; i++) if ($i == "athena-led") count++ } END { print count + 0 }')
luci_count=$(printf '%s\n' "$device_block" | awk '{ for (i = 1; i <= NF; i++) if ($i == "luci-app-athena-led") count++ } END { print count + 0 }')
[ "$core_count" -eq 1 ] || die "$device image definition must contain exactly one athena-led core"
[ "$luci_count" -eq 1 ] || die "$device image definition must contain exactly one luci-app-athena-led"

echo "Athena LED artifact guard passed via $image (target-level manifest has no per-device entry)"
