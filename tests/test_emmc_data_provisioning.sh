#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/uci-defaults/98-provision-emmc-data"
CONFIGURER="$ROOT_DIR/Scripts/ConfigureEmmcDataProvisioning.sh"
CORE_WF="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
RE_MESH_WF="$ROOT_DIR/.github/workflows/RE-Mesh-BUILD.yml"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

[ -x "$SCRIPT" ] || { echo "missing executable first-boot eMMC data provisioner"; exit 1; }
[ -x "$CONFIGURER" ] || { echo "missing eMMC data workflow configurer"; exit 1; }
[ -f "$CORE_WF" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$RE_MESH_WF" ] || { echo "missing RE mesh workflow"; exit 1; }
sh -n "$SCRIPT"
sh -n "$CONFIGURER"

# Static guards: no broad "largest partition" selection or generic label can
# enter the destructive first-boot path.
grep -Fq 'jdcloud,re-ss-01|jdcloud,re-cs-02|jdcloud,re-cs-07' "$SCRIPT" || {
	echo "provisioner does not have the reviewed JDCloud board allowlist"
	exit 1
}
grep -Fq 'rootfs_data' "$SCRIPT" || {
	echo "provisioner does not verify the expected rootfs topology"
	exit 1
}
grep -Fq 'sgdisk -e' "$SCRIPT" || {
	echo "provisioner does not repair a stale backup GPT before allocating tail space"
	exit 1
}
grep -Fq -- '--backup=$backup' "$SCRIPT" || {
	echo "provisioner does not save a GPT backup before mutation"
	exit 1
}
if grep -Eq 'largest|userdata|mkfs\.ext4 .*mmcblk[0-9]$' "$SCRIPT"; then
	echo "provisioner contains an unsafe generic partition-selection path"
	exit 1
fi

grep -q '^      WRT_EMMC_DATA_PROVISIONING:' "$CORE_WF" || {
	echo "WRT-CORE does not expose the eMMC provisioning gate"
	exit 1
}
grep -Fq 'ConfigureEmmcDataProvisioning.sh' "$CORE_WF" || {
	echo "WRT-CORE does not configure the eMMC provisioning overlay"
	exit 1
}
grep -Fq 'WRT_EMMC_DATA_PROVISIONING: true' "$RE_MESH_WF" || {
	echo "RE-SS-01 is not the first guarded device gate"
	exit 1
}

CONFIG_CASE="$TMP_ROOT/config"
mkdir -p "$CONFIG_CASE/files/etc/config"
cp "$ROOT_DIR/files/etc/config/agent-storage" "$CONFIG_CASE/files/etc/config/agent-storage"
"$CONFIGURER" "$CONFIG_CASE/files" true
grep -Fq "option enabled '1'" "$CONFIG_CASE/files/etc/config/agent-storage" || {
	echo "configurer did not enable the reviewed device gate"
	exit 1
}
"$CONFIGURER" "$CONFIG_CASE/files" false
grep -Fq "option enabled '0'" "$CONFIG_CASE/files/etc/config/agent-storage" || {
	echo "configurer did not disable the device gate"
	exit 1
}
if "$CONFIGURER" "$CONFIG_CASE/files" unsafe >/dev/null 2>&1; then
	echo "configurer accepted an invalid boolean"
	exit 1
fi

write_table() {
	local path="$1" last_end="$2"
	printf '%s\n' \
		'Disk /dev/mmcblk0: 15269888 sectors, 7.3 GiB' \
		'Partition table holds up to 28 entries' \
		'First usable sector is 34, last usable sector is 15269854' \
		'Number  Start (sector)    End (sector)  Size       Code  Name' \
		'  18           53282         2150433   1024.0 MiB FFFF  rootfs' \
		"  22         2289698         2330657   20.0 MiB   FFFF  rootfs_data" \
		"  26         3125282         $last_end   512.0 MiB  FFFF  swap" >"$path"
}

run_fixture() {
	local case_root="$1"
	shift
	env \
		EMMC_DATA_PROVISION_TESTING=1 \
		EMMC_DATA_TEST_ENABLED=1 \
		EMMC_DATA_TEST_MIN_SIZE_MB=1024 \
		EMMC_DATA_TEST_LABEL=openwrt-data \
		EMMC_DATA_BOARD_FILE="$case_root/board" \
		EMMC_DATA_SYS_BLOCK_ROOT="$case_root/sys/block" \
		EMMC_DATA_DEV_ROOT="$case_root/dev" \
		EMMC_DATA_MOUNTS_FILE="$case_root/mounts" \
		EMMC_DATA_OVERLAY_DIR="$case_root/overlay" \
		EMMC_DATA_PENDING_FILE="$case_root/overlay/pending" \
		EMMC_DATA_TEST_TABLE_FILE="$case_root/table" \
		EMMC_DATA_TEST_STATE_DIR="$case_root/state" \
		"$@" sh "$SCRIPT"
}

setup_case() {
	local case_root="$1" board="$2" last_end="$3"
	mkdir -p "$case_root/sys/block/mmcblk0/queue" "$case_root/state" "$case_root/dev"
	printf '%s\n' "$board" >"$case_root/board"
	printf '%s\n' 512 >"$case_root/sys/block/mmcblk0/queue/logical_block_size"
	printf '%s\n' 15269888 >"$case_root/sys/block/mmcblk0/size"
	: >"$case_root/mounts"
	write_table "$case_root/table" "$last_end"
}

# Known board + exact GPT topology: a new tail partition is backed up, GPT is
# repaired, then only the pending new partition is formatted.
CASE_OK="$TMP_ROOT/ok"
setup_case "$CASE_OK" jdcloud,re-ss-01 4173857
EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_NEW_PARTITION_APPEARS=1 \
	run_fixture "$CASE_OK"
grep -Fq -- '--backup=' "$CASE_OK/state/sgdisk.calls"
grep -Fq -- '-e ' "$CASE_OK/state/sgdisk.calls"
grep -Fq -- '--new=27:4175872:15269854' "$CASE_OK/state/sgdisk.calls"
grep -Fq -- '-F -L openwrt-data' "$CASE_OK/state/mkfs.calls"
[ ! -e "$CASE_OK/overlay/pending" ] || {
	echo "successful provision left a pending marker"
	exit 1
}

# Kernels may need a reboot before exposing a newly-written eMMC partition.
# The marker permits only that exact unformatted new partition to be completed
# on the next boot; it must not create a second partition or select another.
CASE_PENDING="$TMP_ROOT/pending"
setup_case "$CASE_PENDING" jdcloud,re-ss-01 4173857
if EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=0 \
	EMMC_DATA_TEST_NEW_PARTITION_APPEARS=1 \
	run_fixture "$CASE_PENDING"; then
	echo "missing partition node did not defer provisioning"
	exit 1
fi
[ -f "$CASE_PENDING/overlay/pending" ] || {
	echo "missing partition node did not leave a restricted pending marker"
	exit 1
}
[ ! -e "$CASE_PENDING/state/mkfs.calls" ] || {
	echo "unavailable partition node was formatted"
	exit 1
}
EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	run_fixture "$CASE_PENDING"
[ ! -e "$CASE_PENDING/overlay/pending" ] || {
	echo "pending partition was not completed after its device node appeared"
	exit 1
}
grep -Fq -- '-F -L openwrt-data' "$CASE_PENDING/state/mkfs.calls"

# A pending marker cannot authorise formatting a different existing partition.
CASE_TAMPERED="$TMP_ROOT/tampered-marker"
setup_case "$CASE_TAMPERED" jdcloud,re-ss-01 4173857
mkdir -p "$CASE_TAMPERED/overlay"
printf '%s\n' \
	"disk=$CASE_TAMPERED/dev/mmcblk0" \
	'number=18' \
	'start=53282' \
	'end=2150433' \
	'label=openwrt-data' \
	'phase=created' >"$CASE_TAMPERED/overlay/pending"
if EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	run_fixture "$CASE_TAMPERED"; then
	echo "tampered marker was accepted"
	exit 1
fi
[ ! -e "$CASE_TAMPERED/state/mkfs.calls" ] || {
	echo "tampered marker formatted an existing system partition"
	exit 1
}

# If power fails immediately after GPT creation, intent was already persisted.
# On retry, the exact recorded tail partition is verified before formatting.
CASE_INTERRUPTED="$TMP_ROOT/interrupted"
setup_case "$CASE_INTERRUPTED" jdcloud,re-ss-01 4173857
if EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_NEW_PARTITION_APPEARS=1 EMMC_DATA_TEST_STOP_AFTER_NEW=1 \
	run_fixture "$CASE_INTERRUPTED"; then
	echo "simulated post-create power loss did not defer provisioning"
	exit 1
fi
[ -f "$CASE_INTERRUPTED/overlay/pending" ] || {
	echo "post-create interruption did not retain pending intent"
	exit 1
}
EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	run_fixture "$CASE_INTERRUPTED"
[ ! -e "$CASE_INTERRUPTED/overlay/pending" ] || {
	echo "interrupted creation did not recover from exact pending geometry"
	exit 1
}
grep -Fq -- '-F -L openwrt-data' "$CASE_INTERRUPTED/state/mkfs.calls"

# A non-reviewed board must perform no GPT or filesystem operation.
CASE_BOARD="$TMP_ROOT/wrong-board"
setup_case "$CASE_BOARD" generic,unsafe 4173857
EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	run_fixture "$CASE_BOARD"
[ ! -e "$CASE_BOARD/state/sgdisk.calls" ] && [ ! -e "$CASE_BOARD/state/mkfs.calls" ] || {
	echo "unknown board reached a destructive provision path"
	exit 1
}

# Insufficient tail capacity fails before backup/repair/formatting.
CASE_SMALL="$TMP_ROOT/too-small"
setup_case "$CASE_SMALL" jdcloud,re-cs-02 14500000
if EMMC_DATA_TEST_START=14501888 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	run_fixture "$CASE_SMALL"; then
	echo "insufficient tail space was accepted"
	exit 1
fi
[ ! -e "$CASE_SMALL/state/sgdisk.calls" ] && [ ! -e "$CASE_SMALL/state/mkfs.calls" ] || {
	echo "insufficient tail space mutated GPT or formatted a partition"
	exit 1
}

# An existing explicitly-labelled filesystem is delegated unchanged to the
# mount/migration script; it must never be reformatted.
CASE_EXISTING="$TMP_ROOT/existing"
setup_case "$CASE_EXISTING" jdcloud,re-cs-07 4173857
EMMC_DATA_TEST_EXISTING_DATA=1 EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_EXISTING"
[ ! -e "$CASE_EXISTING/state/sgdisk.calls" ] && [ ! -e "$CASE_EXISTING/state/mkfs.calls" ] || {
	echo "existing openwrt-data storage was touched"
	exit 1
}

echo "guarded eMMC data provisioning tests passed"
