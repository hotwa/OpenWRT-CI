#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
PROFILE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
PI_APPEND_LINK="$ROOT_DIR/files/usr/sbin/pi-append-system-link"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

[ -f "$SCRIPT" ] || { echo "missing 99-auto-mount-data script"; exit 1; }
[ -f "$PROFILE" ] || { echo "missing 20-node-agent.sh profile script"; exit 1; }
[ -x "$PI_APPEND_LINK" ] || { echo "missing executable pi-append-system-link"; exit 1; }
bash -n "$SCRIPT"
bash -n "$PROFILE"

if grep -Eq 'lsblk|mkfs|LABEL=\"\(data\|userdata\|' "$SCRIPT"; then
	echo "auto mount script still guesses or formats generic partitions"
	exit 1
fi
grep -Fq 'find_label_opted_data_devices' "$SCRIPT" || {
	echo "auto mount script does not enumerate label-opted-in data partitions"
	exit 1
}
grep -Fq 'fstab.data.uuid' "$SCRIPT" || {
	echo "auto mount script does not support explicit UUID opt-in"
	exit 1
}
grep -Fq 'fstab.data.partuuid' "$SCRIPT" || {
	echo "auto mount script does not support explicit PARTUUID opt-in"
	exit 1
}
if grep -Fq 'fstab.data.device=' "$SCRIPT"; then
	echo "auto mount script persists an unstable /dev path"
	exit 1
fi

run_fixture() {
	local case_root="$1" storage_enabled="${AUTO_MOUNT_DATA_STORAGE_ENABLED:-1}"
	shift
	# Label-only cases represent a reviewed RE provisioning workflow unless a
	# test explicitly supplies another board.
	[ -e "$case_root/board" ] || printf '%s\n' 'jdcloud,re-cs-02' >"$case_root/board"
	env \
		AUTO_MOUNT_DATA_TESTING=1 \
		AUTO_MOUNT_DATA_STORAGE_ENABLED="$storage_enabled" \
		AUTO_MOUNT_DATA_ROOT="$case_root/data" \
		AUTO_MOUNT_ROOT_HOME="$case_root/root" \
		AUTO_MOUNT_OPT_ROOT="$case_root/opt" \
		AUTO_MOUNT_PROC_MOUNTS="$case_root/mounts" \
		AUTO_MOUNT_LOCK_BASE="$case_root/lock" \
		AUTO_MOUNT_BLOCK_INFO="$case_root/block.info" \
		AUTO_MOUNT_FSTAB_RECORD="$case_root/fstab.record" \
		AUTO_MOUNT_DATA_BOARD_FILE="$case_root/board" \
		AUTO_MOUNT_LEGACY_APPROVAL_FILE="$case_root/legacy-approved" \
		"$@" sh "$SCRIPT"
}

# A label alone is not an opt-in on a generic image. Without the reviewed
# agent-storage gate, no mount, fstab write or state migration may occur.
CASE_LABEL_DISABLED="$TMP_ROOT/label-disabled"
mkdir -p "$CASE_LABEL_DISABLED/root"
: >"$CASE_LABEL_DISABLED/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="label-only-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="label-only-part"' >"$CASE_LABEL_DISABLED/block.info"
if AUTO_MOUNT_DATA_STORAGE_ENABLED=0 run_fixture "$CASE_LABEL_DISABLED"; then
	echo "label-only partition mounted while storage policy was disabled"
	exit 1
fi
[ ! -e "$CASE_LABEL_DISABLED/fstab.record" ] || {
	echo "label-only disabled case persisted fstab"
	exit 1
}

# Even an enabled gate cannot make a generic image trust a bare disk label.
CASE_LABEL_UNREVIEWED="$TMP_ROOT/label-unreviewed"
mkdir -p "$CASE_LABEL_UNREVIEWED/root"
printf '%s\n' 'generic,unsafe' >"$CASE_LABEL_UNREVIEWED/board"
: >"$CASE_LABEL_UNREVIEWED/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="label-unreviewed-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="label-unreviewed-part"' >"$CASE_LABEL_UNREVIEWED/block.info"
if run_fixture "$CASE_LABEL_UNREVIEWED"; then
	echo "label-only partition mounted on an unreviewed board"
	exit 1
fi
[ ! -e "$CASE_LABEL_UNREVIEWED/fstab.record" ] || {
	echo "unreviewed label-only case persisted fstab"
	exit 1
}

approve_legacy_data() {
	local case_root="$1" fstype="${2:-ext4}" number="${3:-27}"
	printf '%s\n' \
		'disk=/dev/mmcblk0' \
		"number=$number" \
		'partlabel=data' \
		'uuid=legacy-uuid' \
		'partuuid=legacy-part' \
		"fstype=$fstype" >"$case_root/legacy-approved"
}

# No opted-in candidate: a generic userdata partition must be ignored.
CASE_BAD="$TMP_ROOT/bad-candidate"
mkdir -p "$CASE_BAD/root"
: >"$CASE_BAD/mounts"
printf '%s\n' '/dev/mmcblk0p8: UUID="bad-uuid" LABEL="userdata" TYPE="ext4" PARTUUID="bad-part"' >"$CASE_BAD/block.info"
if run_fixture "$CASE_BAD"; then
	echo "generic userdata label was incorrectly accepted"
	exit 1
fi
[ ! -e "$CASE_BAD/data/multica" ] || {
	echo "agent directories were created without an approved mount"
	exit 1
}

# Approved candidate but failed mount: fail closed without touching source state.
CASE_NOMOUNT="$TMP_ROOT/no-mount"
mkdir -p "$CASE_NOMOUNT/root/.multica"
printf '%s\n' token >"$CASE_NOMOUNT/root/.multica/config.json"
: >"$CASE_NOMOUNT/mounts"
printf '%s\n' '/dev/mmcblk0p9: UUID="data-uuid" LABEL="openwrt-data" TYPE="f2fs" PARTUUID="data-part"' >"$CASE_NOMOUNT/block.info"
if run_fixture "$CASE_NOMOUNT" AUTO_MOUNT_TEST_MOUNT_FAIL=1; then
	echo "mount failure did not fail closed"
	exit 1
fi
[ ! -e "$CASE_NOMOUNT/data/multica" ] || {
	echo "agent directories were created on the root overlay after mount failure"
	exit 1
}
[ -f "$CASE_NOMOUNT/root/.multica/config.json" ] && [ ! -L "$CASE_NOMOUNT/root/.multica" ] || {
	echo "source state changed after mount failure"
	exit 1
}

# Verified mount but failed copy: migration must leave the source directory intact.
CASE_COPYFAIL="$TMP_ROOT/copy-failure"
mkdir -p "$CASE_COPYFAIL/root/.multica"
printf '%s\n' secret >"$CASE_COPYFAIL/root/.multica/config.json"
: >"$CASE_COPYFAIL/mounts"
printf '%s\n' '/dev/mmcblk0p10: UUID="copy-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="copy-part"' >"$CASE_COPYFAIL/block.info"
if run_fixture "$CASE_COPYFAIL" AUTO_MOUNT_TEST_COPY_FAIL=1; then
	echo "copy failure did not stop migration"
	exit 1
fi
[ -f "$CASE_COPYFAIL/root/.multica/config.json" ] && [ ! -L "$CASE_COPYFAIL/root/.multica" ] || {
	echo "copy failure removed or replaced source state"
	exit 1
}

# Successful mount: persist UUID and atomically migrate all pre-existing state.
CASE_OK="$TMP_ROOT/success"
mkdir -p "$CASE_OK/root/.multica" "$CASE_OK/root/.pi" "$CASE_OK/root/.commandcode"
printf '%s\n' multica-state >"$CASE_OK/root/.multica/config.json"
printf '%s\n' role-card >"$CASE_OK/root/.multica/openwrt-agent.md"
printf '%s\n' pi-state >"$CASE_OK/root/.pi/settings.json"
printf '%s\n' commandcode-auth >"$CASE_OK/root/.commandcode/auth.json"
: >"$CASE_OK/mounts"
printf '%s\n' '/dev/mmcblk0p11: UUID="ok-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="ok-part"' >"$CASE_OK/block.info"
run_fixture "$CASE_OK" "AUTO_MOUNT_PI_APPEND_SYSTEM_LINK_BIN=$PI_APPEND_LINK"
[ -L "$CASE_OK/root/.multica" ] && [ "$(readlink "$CASE_OK/root/.multica")" = "$CASE_OK/data/multica" ] || {
	echo "Multica state was not linked to verified data storage"
	exit 1
}
[ -L "$CASE_OK/root/.pi" ] && [ "$(readlink "$CASE_OK/root/.pi")" = "$CASE_OK/data/pi" ] || {
	echo "Pi state was not linked to verified data storage"
	exit 1
}
[ -L "$CASE_OK/root/.pi/agent/APPEND_SYSTEM.md" ] && \
	[ "$(readlink "$CASE_OK/root/.pi/agent/APPEND_SYSTEM.md")" = "$CASE_OK/root/.multica/openwrt-agent.md" ] || {
	echo "Pi APPEND_SYSTEM.md was not linked to the Multica role card"
	exit 1
}
[ -L "$CASE_OK/root/.commandcode" ] && [ "$(readlink "$CASE_OK/root/.commandcode")" = "$CASE_OK/data/commandcode" ] || {
	echo "CommandCode state was not linked to verified data storage"
	exit 1
}
cmp -s "$CASE_OK/root/.multica/config.json" "$CASE_OK/data/multica/config.json"
cmp -s "$CASE_OK/root/.pi/settings.json" "$CASE_OK/data/pi/settings.json"
cmp -s "$CASE_OK/root/.commandcode/auth.json" "$CASE_OK/data/commandcode/auth.json"
[ -d "$CASE_OK/data/smb" ] || {
	echo "isolated Samba data directory was not created"
	exit 1
}
[ -L "$CASE_OK/opt/data" ] && [ "$(readlink "$CASE_OK/opt/data")" = "$CASE_OK/data" ] || {
	echo "missing /opt/data compatibility link"
	exit 1
}
[ -L "$CASE_OK/opt/smb" ] && [ "$(readlink "$CASE_OK/opt/smb")" = "$CASE_OK/data/smb" ] || {
	echo "missing /opt/smb compatibility link"
	exit 1
}
grep -Fxq 'uuid=ok-uuid' "$CASE_OK/fstab.record" || {
	echo "fstab fixture was not persisted by filesystem UUID"
	exit 1
}

# A previously formatted JDCloud p27 with the historical GPT PARTLABEL=data
# must be adopted once, but only on the reviewed boards. Its anonymous
# /mnt/mmcblk0p27 mount is detached before the UUID-backed /data mount.
CASE_LEGACY="$TMP_ROOT/legacy-p27"
mkdir -p "$CASE_LEGACY/root"
printf '%s\n' 'jdcloud,re-cs-02' >"$CASE_LEGACY/board"
printf '%s\n' '/dev/mmcblk0p27 /mnt/mmcblk0p27 ext4 rw 0 0' >"$CASE_LEGACY/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="legacy-uuid" TYPE="ext4" PARTLABEL="data" PARTUUID="legacy-part"' >"$CASE_LEGACY/block.info"
approve_legacy_data "$CASE_LEGACY"
run_fixture "$CASE_LEGACY"
grep -Fq "/dev/mmcblk0p27 $CASE_LEGACY/data ext4" "$CASE_LEGACY/mounts" || {
	echo "reviewed legacy p27 was not mounted at /data"
	exit 1
}
if grep -Fq '/mnt/mmcblk0p27' "$CASE_LEGACY/mounts"; then
	echo "legacy anonymous p27 mount was not safely detached"
	exit 1
fi
grep -Fxq 'uuid=legacy-uuid' "$CASE_LEGACY/fstab.record" || {
	echo "legacy p27 was not persisted by UUID"
	exit 1
}

# The same label is never a generic opt-in. It must not be touched on another
# board or when it is mounted at an administrator-chosen path.
CASE_LEGACY_BOARD="$TMP_ROOT/legacy-wrong-board"
mkdir -p "$CASE_LEGACY_BOARD/root"
printf '%s\n' 'generic,unsafe' >"$CASE_LEGACY_BOARD/board"
: >"$CASE_LEGACY_BOARD/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="legacy-uuid" TYPE="ext4" PARTLABEL="data" PARTUUID="legacy-part"' >"$CASE_LEGACY_BOARD/block.info"
if run_fixture "$CASE_LEGACY_BOARD"; then
	echo "legacy p27 was accepted on an unreviewed board"
	exit 1
fi

CASE_LEGACY_BUSY="$TMP_ROOT/legacy-busy"
mkdir -p "$CASE_LEGACY_BUSY/root"
printf '%s\n' 'jdcloud,re-ss-01' >"$CASE_LEGACY_BUSY/board"
printf '%s\n' '/dev/mmcblk0p27 /mnt/administrator-data ext4 rw 0 0' >"$CASE_LEGACY_BUSY/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="legacy-uuid" TYPE="ext4" PARTLABEL="data" PARTUUID="legacy-part"' >"$CASE_LEGACY_BUSY/block.info"
approve_legacy_data "$CASE_LEGACY_BUSY"
if run_fixture "$CASE_LEGACY_BUSY"; then
	echo "administrator-mounted legacy p27 was remounted"
	exit 1
fi
[ ! -e "$CASE_LEGACY_BUSY/data/multica" ] || {
	echo "busy legacy p27 caused state migration"
	exit 1
}

# A p27 with PARTLABEL=data and ext4 on a supported board is now adopted
# directly by the dynamic label-opted-in discovery, without requiring an
# approval file. This is the re-cs-02 / re-ss-01 vendor-preinstalled layout.
CASE_LEGACY_DIRECT="$TMP_ROOT/legacy-direct-mount"
mkdir -p "$CASE_LEGACY_DIRECT/root"
printf '%s\n' 'jdcloud,re-ss-01' >"$CASE_LEGACY_DIRECT/board"
: >"$CASE_LEGACY_DIRECT/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="direct-uuid-9999" TYPE="ext4" PARTLABEL="data" PARTUUID="direct-part"' >"$CASE_LEGACY_DIRECT/block.info"
run_fixture "$CASE_LEGACY_DIRECT"
grep -Fq "/dev/mmcblk0p27 $CASE_LEGACY_DIRECT/data ext4" "$CASE_LEGACY_DIRECT/mounts" || {
	echo "PARTLABEL=data ext4 was not directly mounted without approval"
	exit 1
}
grep -Fxq 'uuid=direct-uuid-9999' "$CASE_LEGACY_DIRECT/fstab.record" || {
	echo "direct-mount PARTLABEL=data ext4 was not persisted by UUID"
	exit 1
}
[ ! -e "$CASE_LEGACY_DIRECT/legacy-approved" ] || {
	echo "direct-mount should not create an approval file"
	exit 1
}

# Legacy JDCloud layouts do not all use p27. The approval record carries the
# exact reviewed GPT number, so a different tail number is safe to adopt and
# no hard-coded /dev/mmcblk0p27 convention can leak into production.
CASE_LEGACY_ALT="$TMP_ROOT/legacy-alt-number"
mkdir -p "$CASE_LEGACY_ALT/root"
printf '%s\n' 'jdcloud,re-cs-07' >"$CASE_LEGACY_ALT/board"
printf '%s\n' '/dev/mmcblk0p19 /mnt/mmcblk0p19 ext4 rw 0 0' >"$CASE_LEGACY_ALT/mounts"
printf '%s\n' '/dev/mmcblk0p19: UUID="legacy-uuid" TYPE="ext4" PARTLABEL="data" PARTUUID="legacy-part"' >"$CASE_LEGACY_ALT/block.info"
approve_legacy_data "$CASE_LEGACY_ALT" ext4 19
run_fixture "$CASE_LEGACY_ALT"
grep -Fq "/dev/mmcblk0p19 $CASE_LEGACY_ALT/data ext4" "$CASE_LEGACY_ALT/mounts" || {
	echo "approved legacy data partition with a non-p27 number was not mounted at /data"
	exit 1
}
grep -Fxq 'uuid=legacy-uuid' "$CASE_LEGACY_ALT/fstab.record" || {
	echo "non-p27 legacy data partition was not persisted by UUID"
	exit 1
}

# The profile must consume the verified data-runtime contract instead of
# blindly selecting /data before the mount/write probe has run. Exact mutable
# paths are guarded by tests/test_data_runtime.sh.
grep -Fq '/var/run/data-runtime.env' "$PROFILE" || {
	echo 'node profile does not consume the verified data-runtime contract'
	exit 1
}
grep -Fq 'persistent:/data' "$PROFILE" || {
	echo 'node profile does not gate the data runtime on persistent state'
	exit 1
}
if grep -Fq 'PNPM_HOME=/data/pnpm/bin' "$PROFILE"; then
	echo 'node profile still hardcodes the obsolete unverified PNPM path'
	exit 1
fi

# pi-subagents must receive an absolute storeRoot: /root/.pi is a symlink to
# /data/pi, so a "~/" schedule root resolves outside the real project and the
# extension fails its trust check. The absolute default must be seeded once,
# without overwriting an operator-provided extension config.
grep -Fq '/data/pi/subagents/schedules' "$SCRIPT" || {
	echo 'auto mount script does not seed the absolute pi-subagents store root'
	exit 1
}
grep -Fq '"scheduledRuns"' "$SCRIPT" || {
	echo 'auto mount script does not configure pi-subagents scheduledRuns'
	exit 1
}
grep -Fq 'subagent_cfg_dir/config.json' "$SCRIPT" || {
	echo 'auto mount script does not guard the pi-subagents config path'
	exit 1
}

# CommandCode model cache: the copy loop must carry commandcode-models.json
# from the firmware onto /data so the first-boot selector and the runtime
# sync service have a catalog even without network.
grep -Fq 'commandcode-models.json' "$SCRIPT" || {
	echo 'auto mount script does not copy commandcode-models.json to /data'
	exit 1
}
grep -Fq 'select_model_from_cache' "$SCRIPT" || {
	echo 'auto mount script does not define select_model_from_cache'
	exit 1
}
grep -Fq 'ensure_default_model_from_cache' "$SCRIPT" || {
	echo 'auto mount script does not define ensure_default_model_from_cache'
	exit 1
}
grep -Fq 'commandcode-model-sync' "$SCRIPT" || {
	echo 'auto mount script does not enable the commandcode-model-sync service'
	exit 1
}

# --- CommandCode provider auto-migration for existing /data devices ---

# Case 1: old device with firmware-default settings.json and build-injected
# CommandCode key must be auto-migrated to defaultProvider=commandcode.
CASE_MIGRATE="$TMP_ROOT/cc-migrate"
mkdir -p "$CASE_MIGRATE/root" "$CASE_MIGRATE/data/pi/agent" "$CASE_MIGRATE/firmware_etc/pi/agent" "$CASE_MIGRATE/firmware_etc/commandcode"
cat >"$CASE_MIGRATE/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B",
  "defaultThinkingLevel": "medium",
  "enableInstallTelemetry": false,
  "defaultProjectTrust": "ask"
}
EOF
printf '%s\n' '{"apiKey":"user_migrate_test_key"}' >"$CASE_MIGRATE/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_MIGRATE/firmware_etc/pi/agent/auth.json"
: >"$CASE_MIGRATE/mounts"
printf '%s\n' '/dev/mmcblk0p12: UUID="migrate-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="migrate-part"' >"$CASE_MIGRATE/block.info"
run_fixture "$CASE_MIGRATE" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_MIGRATE/firmware_etc"
grep -Fq '"defaultProvider": "commandcode"' "$CASE_MIGRATE/data/pi/agent/settings.json" || {
	echo "existing settings.json was not migrated to CommandCode provider"
	exit 1
}
grep -Fq '"defaultModel": "Qwen/Qwen3.8-Flash"' "$CASE_MIGRATE/data/pi/agent/settings.json" || {
	echo "defaultModel was not set to Qwen/Qwen3.8-Flash during CommandCode migration"
	exit 1
}
# Backup of the original settings must exist.
ls "$CASE_MIGRATE/data/pi/agent/"settings.json.bak.* >/dev/null 2>&1 || {
	echo "CommandCode migration did not create a backup of the original settings.json"
	exit 1
}
# auth.json must be carried onto /data.
[ -f "$CASE_MIGRATE/data/pi/agent/auth.json" ] || {
	echo "CommandCode migration did not copy auth.json onto /data"
	exit 1
}
grep -Fq 'user_migrate_test_key' "$CASE_MIGRATE/data/pi/agent/auth.json" || {
	echo "CommandCode migration copied wrong auth.json content"
	exit 1
}
# Managed marker must exist after migration.
[ -f "$CASE_MIGRATE/data/pi/agent/.firmware-settings-managed" ] || {
	echo "CommandCode migration did not create the firmware-settings-managed marker"
	exit 1
}

# Case 1b: a stale /data/commandcode/auth.json left over from an earlier
# manual /login (or an older build) must be replaced by the firmware key,
# with a timestamped backup kept.  The provider resolves
# ~/.commandcode/auth.json before ~/.pi/agent/auth.json, so a dead key there
# would otherwise shadow the injected credential and produce 401s.
CASE_STALE="$TMP_ROOT/cc-stale-key"
mkdir -p "$CASE_STALE/root" "$CASE_STALE/data/pi/agent" "$CASE_STALE/data/commandcode" \
	"$CASE_STALE/firmware_etc/pi/agent" "$CASE_STALE/firmware_etc/commandcode"
printf '%s\n' '{"apiKey":"user_stale_expired_key"}' >"$CASE_STALE/data/commandcode/auth.json"
chmod 600 "$CASE_STALE/data/commandcode/auth.json"
printf '%s\n' '{"apiKey":"user_firmware_fresh_key"}' >"$CASE_STALE/firmware_etc/commandcode/auth.json"
chmod 600 "$CASE_STALE/firmware_etc/commandcode/auth.json"
printf '%s\n' '{"apiKey":"user_firmware_fresh_key"}' >"$CASE_STALE/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_STALE/firmware_etc/pi/agent/auth.json"
: >"$CASE_STALE/mounts"
printf '%s\n' '/dev/mmcblk0p14: UUID="stale-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="stale-part"' >"$CASE_STALE/block.info"
run_fixture "$CASE_STALE" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_STALE/firmware_etc"
grep -Fq 'user_firmware_fresh_key' "$CASE_STALE/data/commandcode/auth.json" || {
	echo "stale /data/commandcode/auth.json was not replaced by the firmware key"
	exit 1
}
ls "$CASE_STALE/data/commandcode/"auth.json.bak.* >/dev/null 2>&1 || {
	echo "stale-key replacement did not keep a timestamped backup"
	exit 1
}
grep -Fq 'user_stale_expired_key' "$CASE_STALE/data/commandcode/"auth.json.bak.* || {
	echo "stale-key backup does not contain the previous key"
	exit 1
}
[ "$(stat -c '%a' "$CASE_STALE/data/commandcode/auth.json")" = "600" ] || {
	echo "replaced commandcode auth.json is not mode 0600"
	exit 1
}

# Case 2: user-customized defaultProvider (not in known firmware-default list)
# must NOT be auto-migrated.
CASE_NOMIGRATE_CUSTOM="$TMP_ROOT/cc-nomigrate-custom"
mkdir -p "$CASE_NOMIGRATE_CUSTOM/root" "$CASE_NOMIGRATE_CUSTOM/data/pi/agent" "$CASE_NOMIGRATE_CUSTOM/firmware_etc/pi/agent"
cat >"$CASE_NOMIGRATE_CUSTOM/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "my-custom-provider",
  "defaultModel": "custom-model",
  "defaultThinkingLevel": "high"
}
EOF
printf '%s\n' '{"apiKey":"user_nomigrate_key"}' >"$CASE_NOMIGRATE_CUSTOM/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_NOMIGRATE_CUSTOM/firmware_etc/pi/agent/auth.json"
: >"$CASE_NOMIGRATE_CUSTOM/mounts"
printf '%s\n' '/dev/mmcblk0p13: UUID="nomigrate-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="nomigrate-part"' >"$CASE_NOMIGRATE_CUSTOM/block.info"
run_fixture "$CASE_NOMIGRATE_CUSTOM" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_NOMIGRATE_CUSTOM/firmware_etc"
grep -Fq '"defaultProvider": "my-custom-provider"' "$CASE_NOMIGRATE_CUSTOM/data/pi/agent/settings.json" || {
	echo "user-customized settings.json was overwritten by CommandCode migration"
	exit 1
}
# No backup should be created when migration is skipped.
ls "$CASE_NOMIGRATE_CUSTOM/data/pi/agent/"settings.json.bak.* >/dev/null 2>&1 && {
	echo "backup was created despite migration being skipped for user-customized settings"
	exit 1
}

# Case 3: managed marker with mismatched mtime (user edited settings after
# firmware wrote it) must NOT be auto-migrated.
CASE_NOMIGRATE_MTIME="$TMP_ROOT/cc-nomigrate-mtime"
mkdir -p "$CASE_NOMIGRATE_MTIME/root" "$CASE_NOMIGRATE_MTIME/data/pi/agent" "$CASE_NOMIGRATE_MTIME/firmware_etc/pi/agent"
cat >"$CASE_NOMIGRATE_MTIME/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B",
  "defaultThinkingLevel": "medium"
}
EOF
# Create marker matching settings mtime, then touch settings to simulate a
# user edit (mtime no longer matches marker).
touch -r "$CASE_NOMIGRATE_MTIME/data/pi/agent/settings.json" "$CASE_NOMIGRATE_MTIME/data/pi/agent/.firmware-settings-managed"
sleep 1
touch "$CASE_NOMIGRATE_MTIME/data/pi/agent/settings.json"
printf '%s\n' '{"apiKey":"user_mtime_key"}' >"$CASE_NOMIGRATE_MTIME/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_NOMIGRATE_MTIME/firmware_etc/pi/agent/auth.json"
: >"$CASE_NOMIGRATE_MTIME/mounts"
printf '%s\n' '/dev/mmcblk0p14: UUID="mtime-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="mtime-part"' >"$CASE_NOMIGRATE_MTIME/block.info"
run_fixture "$CASE_NOMIGRATE_MTIME" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_NOMIGRATE_MTIME/firmware_etc"
grep -Fq '"defaultProvider": "office-sglang"' "$CASE_NOMIGRATE_MTIME/data/pi/agent/settings.json" || {
	echo "settings with mismatched managed-marker mtime was overwritten by CommandCode migration"
	exit 1
}

# Case 4: no firmware-injected CommandCode key means no migration even if
# settings.json has the old default provider.
CASE_NOMIGRATE_NOKEY="$TMP_ROOT/cc-nomigrate-nokey"
mkdir -p "$CASE_NOMIGRATE_NOKEY/root" "$CASE_NOMIGRATE_NOKEY/data/pi/agent" "$CASE_NOMIGRATE_NOKEY/firmware_etc/pi/agent"
cat >"$CASE_NOMIGRATE_NOKEY/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B"
}
EOF
# Intentionally do NOT create firmware_etc/pi/agent/auth.json.
: >"$CASE_NOMIGRATE_NOKEY/mounts"
printf '%s\n' '/dev/mmcblk0p15: UUID="nokey-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="nokey-part"' >"$CASE_NOMIGRATE_NOKEY/block.info"
run_fixture "$CASE_NOMIGRATE_NOKEY" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_NOMIGRATE_NOKEY/firmware_etc"
grep -Fq '"defaultProvider": "office-sglang"' "$CASE_NOMIGRATE_NOKEY/data/pi/agent/settings.json" || {
	echo "settings were migrated despite no CommandCode key being injected"
	exit 1
}

# Case 5: npm symlink for pi-commandcode-provider must be created so Pi
# loads the extension without an explicit --extension flag.  The provider
# path is resolved dynamically from the agent-runtime tree.
CASE_NPM_LINK="$TMP_ROOT/cc-npm-link"
mkdir -p "$CASE_NPM_LINK/root" "$CASE_NPM_LINK/data/pi/agent" \
  "$CASE_NPM_LINK/firmware_etc/pi/agent" "$CASE_NPM_LINK/firmware_etc/commandcode" \
  "$CASE_NPM_LINK/agent-runtime/current/node/lib/node_modules/pi-commandcode-provider"
cat >"$CASE_NPM_LINK/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B"
}
EOF
printf '%s\n' '{"apiKey":"user_npm_link_key"}' >"$CASE_NPM_LINK/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_NPM_LINK/firmware_etc/pi/agent/auth.json"
printf '%s\n' '{"apiKey":"user_npm_link_key"}' >"$CASE_NPM_LINK/firmware_etc/commandcode/auth.json"
chmod 600 "$CASE_NPM_LINK/firmware_etc/commandcode/auth.json"
printf '%s\n' '{"name":"pi-commandcode-provider","version":"1.0.0"}' \
  >"$CASE_NPM_LINK/agent-runtime/current/node/lib/node_modules/pi-commandcode-provider/package.json"
: >"$CASE_NPM_LINK/mounts"
printf '%s\n' '/dev/mmcblk0p16: UUID="npmlink-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="npmlink-part"' >"$CASE_NPM_LINK/block.info"
run_fixture "$CASE_NPM_LINK" \
  "AUTO_MOUNT_FIRMWARE_ETC=$CASE_NPM_LINK/firmware_etc" \
  "COMMANDCODE_PROVIDER_SEARCH_ROOT=$CASE_NPM_LINK/agent-runtime"
[ -L "$CASE_NPM_LINK/data/pi/agent/npm/node_modules/pi-commandcode-provider" ] || {
	echo "npm symlink for pi-commandcode-provider was not created"
	exit 1
}
[ "$(readlink "$CASE_NPM_LINK/data/pi/agent/npm/node_modules/pi-commandcode-provider")" = \
  "$CASE_NPM_LINK/agent-runtime/current/node/lib/node_modules/pi-commandcode-provider" ] || {
	echo "npm symlink points to wrong provider path"
	exit 1
}
# Key injection path consistency: /data/commandcode/auth.json must exist and
# be readable (Pi reads ~/.commandcode/auth.json which symlinks to this).
[ -f "$CASE_NPM_LINK/data/commandcode/auth.json" ] || {
	echo "CommandCode auth.json was not copied to /data/commandcode"
	exit 1
}
grep -Fq 'user_npm_link_key' "$CASE_NPM_LINK/data/commandcode/auth.json" || {
	echo "CommandCode auth.json on /data has wrong content"
	exit 1
}

# Case 6: no agent-runtime tree means npm symlink is skipped gracefully
# (non-fatal).
CASE_NPM_NO_RT="$TMP_ROOT/cc-npm-nort"
mkdir -p "$CASE_NPM_NO_RT/root" "$CASE_NPM_NO_RT/data/pi/agent" \
  "$CASE_NPM_NO_RT/firmware_etc/pi/agent" "$CASE_NPM_NO_RT/firmware_etc/commandcode"
cat >"$CASE_NPM_NO_RT/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B"
}
EOF
printf '%s\n' '{"apiKey":"user_nort_key"}' >"$CASE_NPM_NO_RT/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_NPM_NO_RT/firmware_etc/pi/agent/auth.json"
printf '%s\n' '{"apiKey":"user_nort_key"}' >"$CASE_NPM_NO_RT/firmware_etc/commandcode/auth.json"
chmod 600 "$CASE_NPM_NO_RT/firmware_etc/commandcode/auth.json"
: >"$CASE_NPM_NO_RT/mounts"
printf '%s\n' '/dev/mmcblk0p17: UUID="nort-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="nort-part"' >"$CASE_NPM_NO_RT/block.info"
run_fixture "$CASE_NPM_NO_RT" \
  "AUTO_MOUNT_FIRMWARE_ETC=$CASE_NPM_NO_RT/firmware_etc" \
  "COMMANDCODE_PROVIDER_SEARCH_ROOT=$CASE_NPM_NO_RT/nonexistent-runtime"
# Script must succeed even without an agent-runtime tree.
[ ! -e "$CASE_NPM_NO_RT/data/pi/agent/npm/node_modules/pi-commandcode-provider" ] || {
	echo "npm symlink should not exist when agent-runtime tree is absent"
	exit 1
}

# --- CommandCode model cache: first-boot copy and dynamic selection ---

# Case 7: first boot with no existing /data settings must copy the firmware
# commandcode-models.json cache onto /data and select the first open-source
# model from it as defaultModel.
CASE_CACHE_FIRSTBOOT="$TMP_ROOT/cc-cache-firstboot"
mkdir -p "$CASE_CACHE_FIRSTBOOT/root" \
  "$CASE_CACHE_FIRSTBOOT/firmware_etc/pi/agent" \
  "$CASE_CACHE_FIRSTBOOT/firmware_etc/commandcode"
# Firmware settings (what CommandCodeProviderConfig.sh would produce).
cat >"$CASE_CACHE_FIRSTBOOT/firmware_etc/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "commandcode",
  "defaultModel": "Qwen/Qwen3.8-Flash",
  "defaultThinkingLevel": "medium"
}
EOF
# Firmware model cache with a deepseek flash model (highest priority).
cat >"$CASE_CACHE_FIRSTBOOT/firmware_etc/pi/agent/commandcode-models.json" <<'EOF'
{"object":"list","data":[{"id":"deepseek/deepseek-v4-flash","object":"model"},{"id":"Qwen/Qwen3.8-27B","object":"model"}]}
EOF
printf '%s\n' '{"apiKey":"user_firstboot_key"}' >"$CASE_CACHE_FIRSTBOOT/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_CACHE_FIRSTBOOT/firmware_etc/pi/agent/auth.json"
printf '%s\n' '{"apiKey":"user_firstboot_key"}' >"$CASE_CACHE_FIRSTBOOT/firmware_etc/commandcode/auth.json"
chmod 600 "$CASE_CACHE_FIRSTBOOT/firmware_etc/commandcode/auth.json"
: >"$CASE_CACHE_FIRSTBOOT/mounts"
printf '%s\n' '/dev/mmcblk0p18: UUID="firstboot-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="firstboot-part"' >"$CASE_CACHE_FIRSTBOOT/block.info"
run_fixture "$CASE_CACHE_FIRSTBOOT" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_CACHE_FIRSTBOOT/firmware_etc"
# Cache must be copied onto /data.
[ -f "$CASE_CACHE_FIRSTBOOT/data/pi/agent/commandcode-models.json" ] || {
	echo "commandcode-models.json was not copied to /data at first boot"
	exit 1
}
cmp -s "$CASE_CACHE_FIRSTBOOT/firmware_etc/pi/agent/commandcode-models.json" \
  "$CASE_CACHE_FIRSTBOOT/data/pi/agent/commandcode-models.json" || {
	echo "commandcode-models.json copy does not match firmware source"
	exit 1
}
# defaultModel must be the preferred model from the cache (deepseek flash).
grep -Fq '"defaultModel": "deepseek/deepseek-v4-flash"' "$CASE_CACHE_FIRSTBOOT/data/pi/agent/settings.json" || {
	echo "first-boot defaultModel was not selected from the model cache"
	exit 1
}
# Managed marker must exist after first-boot provisioning.
[ -f "$CASE_CACHE_FIRSTBOOT/data/pi/agent/.firmware-settings-managed" ] || {
	echo "firmware-settings-managed marker missing after first boot"
	exit 1
}

# Case 8: upgrade migration with a firmware cache must select the model from
# the cache instead of hardcoding Qwen/Qwen3.8-Flash.
CASE_MIGRATE_CACHE="$TMP_ROOT/cc-migrate-cache"
mkdir -p "$CASE_MIGRATE_CACHE/root" "$CASE_MIGRATE_CACHE/data/pi/agent" \
  "$CASE_MIGRATE_CACHE/firmware_etc/pi/agent" "$CASE_MIGRATE_CACHE/firmware_etc/commandcode"
cat >"$CASE_MIGRATE_CACHE/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B",
  "defaultThinkingLevel": "medium"
}
EOF
printf '%s\n' '{"apiKey":"user_migcache_key"}' >"$CASE_MIGRATE_CACHE/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_MIGRATE_CACHE/firmware_etc/pi/agent/auth.json"
# Firmware cache with a deepseek flash model (preferred over non-flash).
cat >"$CASE_MIGRATE_CACHE/firmware_etc/pi/agent/commandcode-models.json" <<'EOF'
{"object":"list","data":[{"id":"mistralai/Mistral-Small","object":"model"},{"id":"deepseek/deepseek-v4-flash","object":"model"}]}
EOF
: >"$CASE_MIGRATE_CACHE/mounts"
printf '%s\n' '/dev/mmcblk0p19: UUID="migcache-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="migcache-part"' >"$CASE_MIGRATE_CACHE/block.info"
run_fixture "$CASE_MIGRATE_CACHE" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_MIGRATE_CACHE/firmware_etc"
grep -Fq '"defaultProvider": "commandcode"' "$CASE_MIGRATE_CACHE/data/pi/agent/settings.json" || {
	echo "migration with cache did not flip defaultProvider"
	exit 1
}
grep -Fq '"defaultModel": "deepseek/deepseek-v4-flash"' "$CASE_MIGRATE_CACHE/data/pi/agent/settings.json" || {
	echo "migration with cache did not select preferred model from cache (expected deepseek/deepseek-v4-flash)"
	exit 1
}

# Case 9: user-customized settings (mtime mismatch) must NOT have their
# defaultModel overwritten by ensure_default_model_from_cache.
CASE_USER_LOCKED="$TMP_ROOT/cc-user-locked"
mkdir -p "$CASE_USER_LOCKED/root" \
  "$CASE_USER_LOCKED/firmware_etc/pi/agent" \
  "$CASE_USER_LOCKED/firmware_etc/commandcode" \
  "$CASE_USER_LOCKED/data/pi/agent"
# Pre-existing /data settings with user's custom model.
cat >"$CASE_USER_LOCKED/data/pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "commandcode",
  "defaultModel": "user-custom-model",
  "defaultThinkingLevel": "high"
}
EOF
# Create managed marker then simulate user edit (mtime mismatch).
touch -r "$CASE_USER_LOCKED/data/pi/agent/settings.json" "$CASE_USER_LOCKED/data/pi/agent/.firmware-settings-managed"
sleep 1
touch "$CASE_USER_LOCKED/data/pi/agent/settings.json"
# Firmware cache with a different open-source model.
cat >"$CASE_USER_LOCKED/firmware_etc/pi/agent/commandcode-models.json" <<'EOF'
{"object":"list","data":[{"id":"Qwen/Qwen3.8-Flash","object":"model"}]}
EOF
cat >"$CASE_USER_LOCKED/firmware_etc/pi/agent/settings.json" <<'EOF'
{"defaultProvider":"commandcode","defaultModel":"Qwen/Qwen3.8-Flash"}
EOF
printf '%s\n' '{"apiKey":"user_locked_key"}' >"$CASE_USER_LOCKED/firmware_etc/pi/agent/auth.json"
chmod 600 "$CASE_USER_LOCKED/firmware_etc/pi/agent/auth.json"
printf '%s\n' '{"apiKey":"user_locked_key"}' >"$CASE_USER_LOCKED/firmware_etc/commandcode/auth.json"
chmod 600 "$CASE_USER_LOCKED/firmware_etc/commandcode/auth.json"
: >"$CASE_USER_LOCKED/mounts"
printf '%s\n' '/dev/mmcblk0p20: UUID="locked-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="locked-part"' >"$CASE_USER_LOCKED/block.info"
run_fixture "$CASE_USER_LOCKED" "AUTO_MOUNT_FIRMWARE_ETC=$CASE_USER_LOCKED/firmware_etc"
# User's custom model must survive.
grep -Fq '"defaultModel": "user-custom-model"' "$CASE_USER_LOCKED/data/pi/agent/settings.json" || {
	echo "user-customized defaultModel was overwritten despite mtime mismatch"
	exit 1
}


# ============================================================================
# Dynamic label-opted-in discovery tests (PARTLABEL=data|openwrt-data,
# LABEL=openwrt-data) — covers re-ss-01, re-cs-02, re-cs-07 layouts.
# ============================================================================

# --- re-ss-01 scenario: fstab.data.uuid already exists -> main path ---
# When fstab.data.uuid is set, 99 must go through the requested_uuid branch
# and mount by UUID, never entering the label fallback. A decoy PARTLABEL=data
# device with a different UUID must NOT be selected.
CASE_FSTAB_UUID="$TMP_ROOT/fstab-uuid-mainpath"
mkdir -p "$CASE_FSTAB_UUID/root"
printf '%s\n' 'jdcloud,re-ss-01' >"$CASE_FSTAB_UUID/board"
: >"$CASE_FSTAB_UUID/mounts"
cat >"$CASE_FSTAB_UUID/block.info" <<'EOF'
/dev/mmcblk0p27: UUID="resss01-uuid-1234" LABEL="openwrt-data" TYPE="ext4" PARTLABEL="openwrt-data" PARTUUID="resss01-part"
/dev/mmcblk0p26: UUID="decoy-uuid" TYPE="ext4" PARTLABEL="data" PARTUUID="decoy-part"
EOF
run_fixture "$CASE_FSTAB_UUID" AUTO_MOUNT_TEST_FSTAB_UUID=resss01-uuid-1234
grep -Fq "/dev/mmcblk0p27 $CASE_FSTAB_UUID/data ext4" "$CASE_FSTAB_UUID/mounts" || {
	echo "fstab.uuid main path did not mount the UUID-matched p27"
	exit 1
}
if grep -Fq '/dev/mmcblk0p26' "$CASE_FSTAB_UUID/mounts"; then
	echo "fstab.uuid main path incorrectly selected the decoy PARTLABEL=data device"
	exit 1
fi
grep -Fxq 'uuid=resss01-uuid-1234' "$CASE_FSTAB_UUID/fstab.record" || {
	echo "fstab.uuid main path did not persist the correct UUID"
	exit 1
}

# --- re-cs-02 scenario: PARTLABEL=data ext4, no fstab, no approval ---
# A vendor-preinstalled ext4 with PARTLABEL=data (no LABEL) must be mounted
# directly without an approval file. The anonymous /mnt/mmcblk0p27 mount is
# detached before the /data mount.
CASE_PARTLABEL_DATA="$TMP_ROOT/partlabel-data-ext4"
mkdir -p "$CASE_PARTLABEL_DATA/root"
printf '%s\n' 'jdcloud,re-cs-02' >"$CASE_PARTLABEL_DATA/board"
printf '%s\n' '/dev/mmcblk0p27 /mnt/mmcblk0p27 ext4 rw 0 0' >"$CASE_PARTLABEL_DATA/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="recs02-uuid-5678" TYPE="ext4" PARTLABEL="data" PARTUUID="recs02-part"' >"$CASE_PARTLABEL_DATA/block.info"
run_fixture "$CASE_PARTLABEL_DATA"
grep -Fq "/dev/mmcblk0p27 $CASE_PARTLABEL_DATA/data ext4" "$CASE_PARTLABEL_DATA/mounts" || {
	echo "PARTLABEL=data ext4 was not mounted at /data"
	exit 1
}
if grep -Fq '/mnt/mmcblk0p27' "$CASE_PARTLABEL_DATA/mounts"; then
	echo "anonymous p27 mount was not detached before /data mount"
	exit 1
fi
grep -Fxq 'uuid=recs02-uuid-5678' "$CASE_PARTLABEL_DATA/fstab.record" || {
	echo "PARTLABEL=data ext4 was not persisted by UUID"
	exit 1
}
[ ! -e "$CASE_PARTLABEL_DATA/legacy-approved" ] || {
	echo "PARTLABEL=data ext4 should not require an approval file"
	exit 1
}

# --- PARTLABEL=openwrt-data ext4, no fstab -> direct mount ---
CASE_PARTLABEL_OWRT="$TMP_ROOT/partlabel-openwrt-data"
mkdir -p "$CASE_PARTLABEL_OWRT/root"
printf '%s\n' 'jdcloud,re-ss-01' >"$CASE_PARTLABEL_OWRT/board"
: >"$CASE_PARTLABEL_OWRT/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="pl-owrt-uuid" TYPE="ext4" PARTLABEL="openwrt-data" PARTUUID="pl-owrt-part"' >"$CASE_PARTLABEL_OWRT/block.info"
run_fixture "$CASE_PARTLABEL_OWRT"
grep -Fq "/dev/mmcblk0p27 $CASE_PARTLABEL_OWRT/data ext4" "$CASE_PARTLABEL_OWRT/mounts" || {
	echo "PARTLABEL=openwrt-data ext4 was not mounted"
	exit 1
}
grep -Fxq 'uuid=pl-owrt-uuid' "$CASE_PARTLABEL_OWRT/fstab.record" || {
	echo "PARTLABEL=openwrt-data ext4 was not persisted by UUID"
	exit 1
}

# --- f2fs with PARTLABEL=data is also accepted ---
CASE_PARTLABEL_F2FS="$TMP_ROOT/partlabel-data-f2fs"
mkdir -p "$CASE_PARTLABEL_F2FS/root"
printf '%s\n' 'jdcloud,re-cs-07' >"$CASE_PARTLABEL_F2FS/board"
: >"$CASE_PARTLABEL_F2FS/mounts"
printf '%s\n' '/dev/mmcblk0p24: UUID="f2fs-uuid" TYPE="f2fs" PARTLABEL="data" PARTUUID="f2fs-part"' >"$CASE_PARTLABEL_F2FS/block.info"
run_fixture "$CASE_PARTLABEL_F2FS"
grep -Fq "/dev/mmcblk0p24 $CASE_PARTLABEL_F2FS/data f2fs" "$CASE_PARTLABEL_F2FS/mounts" || {
	echo "PARTLABEL=data f2fs was not mounted"
	exit 1
}
grep -Fxq 'fstype=f2fs' "$CASE_PARTLABEL_F2FS/fstab.record" || {
	echo "PARTLABEL=data f2fs was not persisted with fstype=f2fs"
	exit 1
}

# --- Non-supported board must NOT recognize PARTLABEL=data ---
CASE_PARTLABEL_BADBOARD="$TMP_ROOT/partlabel-bad-board"
mkdir -p "$CASE_PARTLABEL_BADBOARD/root"
printf '%s\n' 'generic,unsafe' >"$CASE_PARTLABEL_BADBOARD/board"
: >"$CASE_PARTLABEL_BADBOARD/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="badboard-uuid" TYPE="ext4" PARTLABEL="data" PARTUUID="badboard-part"' >"$CASE_PARTLABEL_BADBOARD/block.info"
if run_fixture "$CASE_PARTLABEL_BADBOARD"; then
	echo "PARTLABEL=data ext4 was accepted on an unreviewed board"
	exit 1
fi
[ ! -e "$CASE_PARTLABEL_BADBOARD/fstab.record" ] || {
	echo "unreviewed board persisted fstab"
	exit 1
}

# --- Non ext4/f2fs (e.g. xfs) with PARTLABEL=data must be rejected ---
CASE_PARTLABEL_XFS="$TMP_ROOT/partlabel-data-xfs"
mkdir -p "$CASE_PARTLABEL_XFS/root"
printf '%s\n' 'jdcloud,re-cs-02' >"$CASE_PARTLABEL_XFS/board"
: >"$CASE_PARTLABEL_XFS/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="xfs-uuid" TYPE="xfs" PARTLABEL="data" PARTUUID="xfs-part"' >"$CASE_PARTLABEL_XFS/block.info"
if run_fixture "$CASE_PARTLABEL_XFS"; then
	echo "PARTLABEL=data xfs was incorrectly accepted"
	exit 1
fi
[ ! -e "$CASE_PARTLABEL_XFS/fstab.record" ] || {
	echo "xfs partition persisted fstab"
	exit 1
}

# --- Multiple label-opted-in candidates must be rejected (ambiguous) ---
CASE_MULTI_CANDIDATE="$TMP_ROOT/multi-label-candidates"
mkdir -p "$CASE_MULTI_CANDIDATE/root"
printf '%s\n' 'jdcloud,re-cs-02' >"$CASE_MULTI_CANDIDATE/board"
: >"$CASE_MULTI_CANDIDATE/mounts"
cat >"$CASE_MULTI_CANDIDATE/block.info" <<'EOF'
/dev/mmcblk0p27: UUID="multi-uuid-1" TYPE="ext4" PARTLABEL="data" PARTUUID="multi-part-1"
/dev/mmcblk0p28: UUID="multi-uuid-2" TYPE="ext4" LABEL="openwrt-data" PARTUUID="multi-part-2"
EOF
if run_fixture "$CASE_MULTI_CANDIDATE"; then
	echo "multiple label-opted-in candidates were not rejected"
	exit 1
fi
[ ! -e "$CASE_MULTI_CANDIDATE/fstab.record" ] || {
	echo "ambiguous multi-candidate case persisted fstab"
	exit 1
}

# --- Priority: PARTLABEL=data ext4 wins over LABEL=openwrt-data when both
#     exist but only one is a valid candidate (the other has no fs).
#     Actually both are valid candidates -> ambiguous. Test that a decoy
#     PARTLABEL=data without ext4/f2fs is filtered out, leaving the
#     LABEL=openwrt-data ext4 as the sole candidate.
CASE_DECOY_FILTERED="$TMP_ROOT/decoy-partlabel-raw"
mkdir -p "$CASE_DECOY_FILTERED/root"
printf '%s\n' 'jdcloud,re-cs-02' >"$CASE_DECOY_FILTERED/board"
: >"$CASE_DECOY_FILTERED/mounts"
cat >"$CASE_DECOY_FILTERED/block.info" <<'EOF'
/dev/mmcblk0p27: UUID="raw-decoy-uuid" PARTLABEL="data" PARTUUID="raw-decoy-part"
/dev/mmcblk0p28: UUID="valid-label-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="valid-label-part"
EOF
run_fixture "$CASE_DECOY_FILTERED"
grep -Fq "/dev/mmcblk0p28 $CASE_DECOY_FILTERED/data ext4" "$CASE_DECOY_FILTERED/mounts" || {
	echo "raw PARTLABEL=data decoy was not filtered out; LABEL=openwrt-data ext4 was not selected"
	exit 1
}
grep -Fxq 'uuid=valid-label-uuid' "$CASE_DECOY_FILTERED/fstab.record" || {
	echo "filtered-decoy case did not persist the correct UUID"
	exit 1
}

echo "auto mount data fixture tests passed"
