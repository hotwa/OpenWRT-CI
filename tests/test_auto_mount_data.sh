#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
PROFILE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

[ -f "$SCRIPT" ] || { echo "missing 99-auto-mount-data script"; exit 1; }
[ -f "$PROFILE" ] || { echo "missing 20-node-agent.sh profile script"; exit 1; }
bash -n "$SCRIPT"
bash -n "$PROFILE"

if grep -Eq 'lsblk|mkfs|LABEL=\"\(data\|userdata\|' "$SCRIPT"; then
	echo "auto mount script still guesses or formats generic partitions"
	exit 1
fi
grep -Fq 'find_devices LABEL openwrt-data' "$SCRIPT" || {
	echo "auto mount script does not require LABEL=openwrt-data"
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
	local case_root="$1"
	shift
	env \
		AUTO_MOUNT_DATA_TESTING=1 \
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

approve_legacy_p27() {
	local case_root="$1" fstype="${2:-ext4}"
	printf '%s\n' \
		'disk=/dev/mmcblk0' \
		'number=27' \
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
printf '%s\n' pi-state >"$CASE_OK/root/.pi/settings.json"
printf '%s\n' commandcode-auth >"$CASE_OK/root/.commandcode/auth.json"
: >"$CASE_OK/mounts"
printf '%s\n' '/dev/mmcblk0p11: UUID="ok-uuid" LABEL="openwrt-data" TYPE="ext4" PARTUUID="ok-part"' >"$CASE_OK/block.info"
run_fixture "$CASE_OK"
[ -L "$CASE_OK/root/.multica" ] && [ "$(readlink "$CASE_OK/root/.multica")" = "$CASE_OK/data/multica" ] || {
	echo "Multica state was not linked to verified data storage"
	exit 1
}
[ -L "$CASE_OK/root/.pi" ] && [ "$(readlink "$CASE_OK/root/.pi")" = "$CASE_OK/data/pi" ] || {
	echo "Pi state was not linked to verified data storage"
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
approve_legacy_p27 "$CASE_LEGACY"
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
approve_legacy_p27 "$CASE_LEGACY_BUSY"
if run_fixture "$CASE_LEGACY_BUSY"; then
	echo "administrator-mounted legacy p27 was remounted"
	exit 1
fi
[ ! -e "$CASE_LEGACY_BUSY/data/multica" ] || {
	echo "busy legacy p27 caused state migration"
	exit 1
}

# A p27 with the old label but no approval bound to its UUID/PARTUUID is not
# sufficient to migrate state. This catches a copied or unexpected layout.
CASE_LEGACY_UNAPPROVED="$TMP_ROOT/legacy-unapproved"
mkdir -p "$CASE_LEGACY_UNAPPROVED/root"
printf '%s\n' 'jdcloud,re-ss-01' >"$CASE_LEGACY_UNAPPROVED/board"
: >"$CASE_LEGACY_UNAPPROVED/mounts"
printf '%s\n' '/dev/mmcblk0p27: UUID="legacy-uuid" TYPE="ext4" PARTLABEL="data" PARTUUID="legacy-part"' >"$CASE_LEGACY_UNAPPROVED/block.info"
if run_fixture "$CASE_LEGACY_UNAPPROVED"; then
	echo "unapproved legacy p27 was adopted"
	exit 1
fi

for setting in 'PNPM_HOME=/data/pnpm/bin' 'PNPM_STORE_DIR=/data/pnpm/store' 'npm_config_cache=/data/npm'; do
grep -Fq "$setting" "$PROFILE" || {
	echo "node profile does not keep mutable package state on /data: $setting"
	exit 1
}
done

echo "auto mount data fixture tests passed"
