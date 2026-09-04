#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

if grep -Fq 'WRT_DATA_RUNTIME' "$CORE"; then
	echo 'the universal data runtime must not have a caller-controlled opt-out'
	exit 1
fi

for path in \
	'files/etc/init.d/data-runtime' \
	'files/etc/init.d/rclone-data-backup' \
	'files/etc/uci-defaults/94-zram-swap-defaults' \
	'files/etc/uci-defaults/98-provision-emmc-data' \
	'files/etc/uci-defaults/99-auto-mount-data' \
	'files/usr/sbin/openwrt-data-storage-diagnose' \
	'files/usr/sbin/rclone-data-backup'; do
	grep -Fq "./$path ./wrt/$path" "$CORE" || {
		echo "WRT-CORE does not inject $path" >&2
		exit 1
	}
done

grep -Fq 'destructive GPT provisioning remains disabled by its UCI gate' "$CORE"
grep -Fq 'read-only data storage diagnosis helper' "$CORE"
grep -Fq 'WRTBAK_DEVICE_ALIAS is not safe for the data backup namespace' "$CORE"
grep -Fq 'option device_alias' "$CORE"
grep -Fq 'Preserve that explicit' "$CORE"
grep -Fq '[ ! -f ./wrt/files/etc/config/agent-storage ]' "$CORE"

echo 'WRT-CORE data runtime injection guards passed'
