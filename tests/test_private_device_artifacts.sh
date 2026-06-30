#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/PrivateDeviceArtifacts.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$SCRIPT" ] || { echo "missing PrivateDeviceArtifacts.sh"; exit 1; }
[ "$(git ls-files --stage -- "$SCRIPT" | awk '{print $1}')" = "100755" ] || {
	echo "PrivateDeviceArtifacts.sh is not marked executable"
	exit 1
}

grep -q 'Scripts/PrivateDeviceArtifacts.sh ./bin/targets ./upload-private-devices' "$WORKFLOW" || {
	echo "WRT-CORE.yml does not prepare private per-device artifacts"
	exit 1
}

grep -q "if: env.WRT_PRIVATE_BUILD == 'true' && env.WRT_TEST != 'true'" "$WORKFLOW" || {
	echo "private per-device artifact upload is not gated to private non-test builds"
	exit 1
}

for device in jdcloud_re-cs-02 jdcloud_re-cs-07 jdcloud_re-ss-01 jdcloud_re-ss-02; do
	grep -q "${device}-private" "$WORKFLOW" || {
		echo "WRT-CORE.yml does not upload a private artifact for $device"
		exit 1
	}
	grep -q "./wrt/upload-private-devices/$device/" "$WORKFLOW" || {
		echo "WRT-CORE.yml does not upload the $device private device directory"
		exit 1
	}
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TARGET_DIR="$WORK_DIR/bin/targets/qualcommax/ipq60xx"
OUTPUT_DIR="$WORK_DIR/private-devices"
mkdir -p "$TARGET_DIR"

printf 'firmware\n' >"$TARGET_DIR/openwrt-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-sysupgrade.bin"
printf 'factory\n' >"$TARGET_DIR/openwrt-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-factory.bin"
printf 'other\n' >"$TARGET_DIR/openwrt-qualcommax-ipq60xx-redmi_ax5-squashfs-sysupgrade.bin"
printf 'manifest\n' >"$TARGET_DIR/openwrt-qualcommax-ipq60xx.manifest"
printf 'buildinfo\n' >"$TARGET_DIR/openwrt-qualcommax-ipq60xx.buildinfo"
printf 'full sha list\n' >"$TARGET_DIR/sha256sums"

WRT_PRIVATE_BUILD=false bash "$SCRIPT" "$WORK_DIR/bin/targets" "$OUTPUT_DIR"
[ ! -e "$OUTPUT_DIR" ] || {
	echo "public builds should not prepare private per-device artifacts"
	exit 1
}

WRT_PRIVATE_BUILD=true PRIVATE_DEVICE_ARTIFACTS="jdcloud_re-ss-01" bash "$SCRIPT" "$WORK_DIR/bin/targets" "$OUTPUT_DIR"

DEVICE_DIR="$OUTPUT_DIR/jdcloud_re-ss-01"
[ -f "$DEVICE_DIR/openwrt-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-sysupgrade.bin" ] || {
	echo "private artifact is missing the jdcloud_re-ss-01 sysupgrade image"
	exit 1
}
[ -f "$DEVICE_DIR/openwrt-qualcommax-ipq60xx.manifest" ] || {
	echo "private artifact is missing the target manifest"
	exit 1
}
[ -f "$DEVICE_DIR/openwrt-qualcommax-ipq60xx.buildinfo" ] || {
	echo "private artifact is missing the target buildinfo"
	exit 1
}
[ -f "$DEVICE_DIR/sha256sums" ] || {
	echo "private artifact is missing generated sha256sums"
	exit 1
}

if [ -e "$DEVICE_DIR/openwrt-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-factory.bin" ]; then
	echo "private artifact should not include factory images"
	exit 1
fi

if [ -e "$DEVICE_DIR/openwrt-qualcommax-ipq60xx-redmi_ax5-squashfs-sysupgrade.bin" ]; then
	echo "private artifact should not include other device images"
	exit 1
fi

grep -q 'jdcloud_re-ss-01-squashfs-sysupgrade.bin' "$DEVICE_DIR/sha256sums" || {
	echo "generated sha256sums does not include the sysupgrade image"
	exit 1
}

echo "private device artifact guard passed"
