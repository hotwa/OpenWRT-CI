#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/FirmwareFleetDeploy.sh"
INVENTORY="$ROOT_DIR/Config/firmware-fleet.json"
CD_WORKFLOW="$ROOT_DIR/.github/workflows/FIRMWARE-FLEET-CD.yml"
SPACE_GUARD="$ROOT_DIR/files/usr/sbin/openwrt-upgrade-space"
SPACE_INIT="$ROOT_DIR/files/etc/init.d/upgrade-tmp-capacity"

[ -x "$SCRIPT" ] || { echo "firmware fleet deploy script is not executable" >&2; exit 1; }
[ -f "$INVENTORY" ] || { echo "firmware fleet inventory is missing" >&2; exit 1; }
[ -f "$CD_WORKFLOW" ] || { echo "default-off fleet CD workflow is missing" >&2; exit 1; }
[ -x "$SPACE_GUARD" ] || { echo "firmware upgrade-space guard is missing or not executable" >&2; exit 1; }
[ -x "$SPACE_INIT" ] || { echo "firmware upgrade tmpfs init service is missing or not executable" >&2; exit 1; }
sh -n "$SPACE_GUARD"
sh -n "$SPACE_INIT"
grep -Fq 'jdcloud,re-ss-01)' "$SPACE_GUARD"
grep -Fq 'size=512m /tmp' "$SPACE_GUARD"
grep -Fq 'image_kib + 49152' "$SPACE_GUARD"
grep -Fq 'memory-plus-swap' "$SPACE_GUARD"
grep -Fq 'openwrt-upgrade-space prepare' "$SPACE_INIT"
grep -Fq 'guard_remote="$remote_path.space-check"' "$SCRIPT"
grep -Fq 'remote upgrade-space guard checksum mismatch' "$SCRIPT"

# The remote space guard must run after checksum verification but before either
# sysupgrade's image test or the mutating upgrade command.
space_first_line="$(grep -nF "\$guard_remote' check '\$remote_path" "$SCRIPT" | head -n 1 | cut -d: -f1)"
test_line="$(grep -nF 'sysupgrade -T' "$SCRIPT" | cut -d: -f1)"
space_last_line="$(grep -nF "\$guard_remote' check '\$remote_path" "$SCRIPT" | tail -n 1 | cut -d: -f1)"
upgrade_line="$(grep -nF 'sysupgrade -c' "$SCRIPT" | cut -d: -f1)"
[ "$space_first_line" -lt "$test_line" ] && [ "$test_line" -lt "$space_last_line" ] && [ "$space_last_line" -lt "$upgrade_line" ]
[ "$(grep -Fc "\$guard_remote' check '\$remote_path" "$SCRIPT")" -eq 2 ]

bash "$SCRIPT" validate-inventory --inventory "$INVENTORY" >/dev/null
grep -A8 '^      DEPLOY:' "$CD_WORKFLOW" | grep -Fq 'default: false'
if grep -Eq '^[[:space:]]*schedule:' "$CD_WORKFLOW"; then
	echo "fleet CD must remain unscheduled until explicitly approved" >&2
	exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'find "$WORK_DIR" -depth -delete' EXIT

# shellcheck source=/dev/null
. "$SCRIPT"

jq '.devices += [.devices[0]]' "$INVENTORY" > "$WORK_DIR/duplicate-id.json"
if bash "$SCRIPT" validate-inventory --inventory "$WORK_DIR/duplicate-id.json" >/dev/null 2>&1; then
	echo "fleet validator accepted a duplicate device identity" >&2
	exit 1
fi

jq '(.devices[] | select(.id == "cs02-11").magicdns) = "cs02-12.hs.jmsu.top"' "$INVENTORY" > "$WORK_DIR/wrong-fqdn.json"
if bash "$SCRIPT" validate-inventory --inventory "$WORK_DIR/wrong-fqdn.json" >/dev/null 2>&1; then
	echo "fleet validator accepted a mismatched MagicDNS name" >&2
	exit 1
fi

jq '(.devices[] | select(.id == "ss01-12").lan_cidr) = "192.168.11.0/24"' "$INVENTORY" > "$WORK_DIR/overlap.json"
if bash "$SCRIPT" validate-inventory --inventory "$WORK_DIR/overlap.json" >/dev/null 2>&1; then
	echo "fleet validator accepted an overlapping LAN CIDR" >&2
	exit 1
fi

ARTIFACT_DIR="$WORK_DIR/artifact"
mkdir -p "$ARTIFACT_DIR"
printf 'firmware\n' > "$ARTIFACT_DIR/openwrt-jdcloud_re-cs-02-squashfs-sysupgrade.bin"
jq -n \
	--arg config IPQ60XX-RE-CS-02 \
	--arg device jdcloud_re-cs-02 \
	--arg commit 0123456789abcdef0123456789abcdef01234567 \
	'{config:$config, required_device:$device, source_commit:$commit}' > "$ARTIFACT_DIR/metadata.json"
(
	cd "$ARTIFACT_DIR"
	find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
)

[ "$(verify_extracted_artifact "$ARTIFACT_DIR" IPQ60XX-RE-CS-02 jdcloud_re-cs-02)" = "$ARTIFACT_DIR/openwrt-jdcloud_re-cs-02-squashfs-sysupgrade.bin" ] || {
	echo "artifact verifier did not return the exact sysupgrade image" >&2
	exit 1
}
printf 'tampered\n' >> "$ARTIFACT_DIR/openwrt-jdcloud_re-cs-02-squashfs-sysupgrade.bin"
if bash -c '
  set -euo pipefail
  . "$1"
  verify_extracted_artifact "$2" IPQ60XX-RE-CS-02 jdcloud_re-cs-02 >/dev/null
' _ "$SCRIPT" "$ARTIFACT_DIR" >/dev/null 2>&1; then
	echo "artifact verifier accepted a checksum mismatch" >&2
	exit 1
fi

echo "firmware fleet deploy test passed"
