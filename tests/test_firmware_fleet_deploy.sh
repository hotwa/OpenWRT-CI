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
grep -Fq 'cat /etc/openwrt-ci/firmware-commit' "$SCRIPT"
grep -Fq '[ "$boot_commit" = "$expected_commit" ]' "$SCRIPT"

# The remote space guard must run after checksum verification but before either
# sysupgrade's image test or the mutating upgrade command.
space_first_line="$(grep -nF "\$guard_remote' check '\$remote_path" "$SCRIPT" | head -n 1 | cut -d: -f1)"
test_line="$(grep -nF 'sysupgrade -T' "$SCRIPT" | cut -d: -f1)"
space_last_line="$(grep -nF "\$guard_remote' check '\$remote_path" "$SCRIPT" | tail -n 1 | cut -d: -f1)"
upgrade_line="$(grep -nF 'sysupgrade -c' "$SCRIPT" | cut -d: -f1)"
[ "$space_first_line" -lt "$test_line" ] && [ "$test_line" -lt "$space_last_line" ] && [ "$space_last_line" -lt "$upgrade_line" ]
[ "$(grep -Fc "\$guard_remote' check '\$remote_path" "$SCRIPT")" -eq 2 ]

bash "$SCRIPT" validate-inventory --inventory "$INVENTORY" >/dev/null
# shellcheck source=/dev/null
. "$SCRIPT"
SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
GOOD_RUN_JSON="$(jq -n \
	--arg sha "$SOURCE_SHA" \
	--arg repo hotwa/OpenWRT-CI \
	'{conclusion:"success",head_branch:"main",head_sha:$sha,head_repository:{full_name:$repo},path:".github/workflows/RE-Mesh-BUILD.yml@refs/heads/main"}')"
[ "$(validate_run_payload "$GOOD_RUN_JSON" cs02-11)" = "$SOURCE_SHA" ] || {
	echo "source build validation did not return the run head SHA" >&2
	exit 1
}
if bash -c 'set -euo pipefail; . "$1"; validate_run_payload "$2" cs02-11 >/dev/null' _ "$SCRIPT" "$(jq -n --argjson run "$GOOD_RUN_JSON" '$run | .path = ".github/workflows/RE-CS-07-BUILD.yml@refs/heads/main"')" >/dev/null 2>&1; then
	echo "source build validator accepted the wrong device workflow" >&2
	exit 1
fi
if bash -c 'set -euo pipefail; . "$1"; validate_run_payload "$2" cs02-11 >/dev/null' _ "$SCRIPT" "$(jq -n --argjson run "$GOOD_RUN_JSON" '$run | .head_sha = "not-a-sha"')" >/dev/null 2>&1; then
	echo "source build validator accepted a malformed SHA" >&2
	exit 1
fi
grep -A8 '^      DEPLOY:' "$CD_WORKFLOW" | grep -Fq 'default: false'
if grep -Eq '^[[:space:]]*schedule:' "$CD_WORKFLOW"; then
	echo "fleet CD must remain unscheduled until explicitly approved" >&2
	exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'find "$WORK_DIR" -depth -delete' EXIT

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
	--arg workflow_commit "$SOURCE_SHA" \
	--arg source_commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
	'{config:$config, required_device:$device, workflow_commit:$workflow_commit, source_commit:$source_commit}' > "$ARTIFACT_DIR/metadata.json"
(
	cd "$ARTIFACT_DIR"
	find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
)

[ "$(verify_extracted_artifact "$ARTIFACT_DIR" IPQ60XX-RE-CS-02 jdcloud_re-cs-02 "$SOURCE_SHA")" = "$ARTIFACT_DIR/openwrt-jdcloud_re-cs-02-squashfs-sysupgrade.bin" ] || {
	echo "artifact verifier did not return the exact sysupgrade image" >&2
	exit 1
}
if bash -c '
  set -euo pipefail
  . "$1"
  verify_extracted_artifact "$2" IPQ60XX-RE-CS-02 jdcloud_re-cs-02 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null
' _ "$SCRIPT" "$ARTIFACT_DIR" >/dev/null 2>&1; then
	echo "artifact verifier accepted metadata from a different source commit" >&2
	exit 1
fi
printf 'tampered\n' >> "$ARTIFACT_DIR/openwrt-jdcloud_re-cs-02-squashfs-sysupgrade.bin"
if bash -c '
  set -euo pipefail
  . "$1"
  verify_extracted_artifact "$2" IPQ60XX-RE-CS-02 jdcloud_re-cs-02 0123456789abcdef0123456789abcdef01234567 >/dev/null
' _ "$SCRIPT" "$ARTIFACT_DIR" >/dev/null 2>&1; then
	echo "artifact verifier accepted a checksum mismatch" >&2
	exit 1
fi

remote_exec() {
	printf '%s' "$3" >"$REMOTE_PREFLIGHT_COMMAND_FILE"
	printf 'jdcloud,re-cs-02\t192.168.11.1\t24\tcs02-11\tcs02-11.hs.jmsu.top\n'
}
REMOTE_PREFLIGHT_COMMAND_FILE="$WORK_DIR/cs02-remote-command"
CS02_RECORD="$(jq -c '.devices[] | select(.id == "cs02-11")' "$INVENTORY")"
preflight_record "$CS02_RECORD" "$WORK_DIR/unused-ssh-config" >/dev/null
grep -Fq '[ "$data_state" = persistent ]' "$REMOTE_PREFLIGHT_COMMAND_FILE"
grep -Fq 'block-backed /data mount is unavailable' "$REMOTE_PREFLIGHT_COMMAND_FILE"
if grep -Fq 'openwrt-ci-health' "$REMOTE_PREFLIGHT_COMMAND_FILE"; then
	echo "CD preflight unexpectedly runs service health checks" >&2
	exit 1
fi
remote_exec() {
	printf '%s' "$3" >"$REMOTE_PREFLIGHT_COMMAND_FILE"
	printf 'jdcloud,re-cs-07\t192.168.10.1\t24\tcs07-10\tcs07-10.hs.jmsu.top\n'
}
CS07_RECORD="$(jq -c '.devices[] | select(.id == "cs07-10")' "$INVENTORY")"
preflight_record "$CS07_RECORD" "$WORK_DIR/unused-ssh-config" >/dev/null
grep -Fq '[ "$data_state" = persistent ]' "$REMOTE_PREFLIGHT_COMMAND_FILE"
grep -Fq 'block-backed /data mount is unavailable' "$REMOTE_PREFLIGHT_COMMAND_FILE"
if grep -Fq 'openwrt-ci-health' "$REMOTE_PREFLIGHT_COMMAND_FILE"; then
	echo "CS07 CD preflight unexpectedly runs service health checks" >&2
	exit 1
fi
remote_exec() {
	printf 'jdcloud,re-cs-02\t192.168.13.1\t24\tcs02-11\tcs02-11.hs.jmsu.top\n'
}
if (preflight_record "$CS02_RECORD" "$WORK_DIR/unused-ssh-config") >/dev/null 2>&1; then
	echo "device preflight accepted a LAN address outside its registered /24" >&2
	exit 1
fi
remote_exec() {
	printf 'jdcloud,re-cs-02\t192.168.11.1\t16\tcs02-11\tcs02-11.hs.jmsu.top\n'
}
if (preflight_record "$CS02_RECORD" "$WORK_DIR/unused-ssh-config") >/dev/null 2>&1; then
	echo "device preflight accepted a non-/24 LAN mask" >&2
	exit 1
fi

echo "firmware fleet deploy test passed"
