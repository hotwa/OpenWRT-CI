#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/FirmwareFleetDeploy.sh"
INVENTORY="$ROOT_DIR/Config/firmware-fleet.json"

[ -x "$SCRIPT" ] || { echo "firmware fleet deploy script is not executable" >&2; exit 1; }
[ -f "$INVENTORY" ] || { echo "firmware fleet inventory is missing" >&2; exit 1; }

bash "$SCRIPT" validate-inventory --inventory "$INVENTORY" >/dev/null

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
