#!/bin/bash
set -euo pipefail

TARGET_ROOT="${1:-./bin/targets}"
OUTPUT_ROOT="${2:-./upload-private-devices}"
DEVICE_LIST="${PRIVATE_DEVICE_ARTIFACTS:-jdcloud_re-cs-02 jdcloud_re-cs-07 jdcloud_re-ss-01 jdcloud_re-ss-02}"

if [ "${WRT_PRIVATE_BUILD:-false}" != "true" ]; then
	echo "private device artifacts: public build, skipping"
	exit 0
fi

if [ ! -d "$TARGET_ROOT" ]; then
	echo "private device artifacts: target root not found: $TARGET_ROOT" >&2
	exit 0
fi

rm -rf "$OUTPUT_ROOT"
created=0

copy_metadata() {
	local source_dir="$1"
	local device_dir="$2"
	local meta

	for meta in "$source_dir"/*.manifest "$source_dir"/*.buildinfo; do
		[ -f "$meta" ] || continue
		cp -f "$meta" "$device_dir/"
	done
}

write_sha256sums() {
	local device_dir="$1"

	(
		cd "$device_dir"
		rm -f sha256sums
		find . -maxdepth 1 -type f ! -name sha256sums -print0 |
			sort -z |
			xargs -0 sha256sum >sha256sums
	)
}

for device in $DEVICE_LIST; do
	device_dir="$OUTPUT_ROOT/$device"
	found=0

	while IFS= read -r -d '' firmware; do
		mkdir -p "$device_dir"
		cp -f "$firmware" "$device_dir/"
		copy_metadata "$(dirname "$firmware")" "$device_dir"
		found=1
	done < <(
		find "$TARGET_ROOT" -type f \
			\( -iname "*${device}*sysupgrade*.bin" \
			-o -iname "*${device}*sysupgrade*.img" \
			-o -iname "*${device}*sysupgrade*.itb" \) \
			-print0
	)

	if [ "$found" -eq 1 ]; then
		write_sha256sums "$device_dir"
		created=1
		echo "private device artifacts: prepared $device"
	else
		echo "private device artifacts: no sysupgrade image for $device"
	fi
done

if [ "$created" -ne 1 ]; then
	rm -rf "$OUTPUT_ROOT"
	echo "private device artifacts: no matching device images found"
fi
