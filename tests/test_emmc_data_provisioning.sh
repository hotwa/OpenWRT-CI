#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/uci-defaults/98-provision-emmc-data"
RESUME_INIT="$ROOT_DIR/files/etc/init.d/emmc-data-provision"
CONFIGURER="$ROOT_DIR/Scripts/ConfigureEmmcDataProvisioning.sh"
CORE_WF="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
RE_MESH_WF="$ROOT_DIR/.github/workflows/RE-Mesh-BUILD.yml"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

[ -x "$SCRIPT" ] || { echo "missing executable first-boot eMMC data provisioner"; exit 1; }
[ -x "$RESUME_INIT" ] || { echo "missing executable eMMC provisioning resume init service"; exit 1; }
[ -x "$CONFIGURER" ] || { echo "missing eMMC data workflow configurer"; exit 1; }
[ -f "$CORE_WF" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$RE_MESH_WF" ] || { echo "missing RE mesh workflow"; exit 1; }
sh -n "$SCRIPT"
sh -n "$RESUME_INIT"
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
grep -Fq "0) if [ -n \"\$type\" ]; then printf 'typed:%s' \"\$type\"; else printf raw; fi ;;" "$SCRIPT" || {
	echo "provisioner does not handle BusyBox raw-partition blkid semantics"
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
grep -Fq 'emmc-data-provision enable' "$ROOT_DIR/files/etc/uci-defaults/99-enable-data-runtime" || {
	echo "data runtime defaults do not enable the pending provisioning retry service"
	exit 1
}
grep -Fq '"$WORKER"' "$RESUME_INIT" || {
	echo "resume init does not invoke the reviewed provisioning worker"
	exit 1
}
grep -Fq '"$MOUNTER"' "$RESUME_INIT" || {
	echo "resume init does not invoke the reviewed mount worker"
	exit 1
}
if grep -Eq '^[[:space:]]*(mkfs|sgdisk|partprobe)([[:space:]]|$)' "$RESUME_INIT"; then
	echo "resume init must delegate mutations to the reviewed worker"
	exit 1
fi

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

append_reviewed_p27() {
	local path="$1" number="${2:-27}"
	printf '%s\n' "  $number         4175872        15269854   5.3 GiB    8300  data" >>"$path"
}

# 128GB jdcloud,re-cs-07 layout: p24 is an empty-named 112.6GiB 8300
# partition with no filesystem. The p24 line deliberately ends after "8300"
# so that awk sees an empty $7 (GPT name).
write_128g_table() {
	local path="$1"
	printf '%s\n' \
		'Disk /dev/mmcblk0: 240615424 sectors, 114.7 GiB' \
		'Partition table holds up to 28 entries' \
		'First usable sector is 34, last usable sector is 240615416' \
		'Number  Start (sector)    End (sector)  Size       Code  Name' \
		'  18           53282         4247137   2.0 GiB    FFFF  rootfs' \
		'  22         4247138         4288101   20.0 MiB   FFFF  rootfs_data' \
		'  23         4288102         4289125   512.0 KiB  FFFF  ETHPHYFW' \
		'  24         4429824       240613375   112.6 GiB  8300' >"$path"
}

setup_128g_case() {
	local case_root="$1"
	mkdir -p "$case_root/sys/block/mmcblk0/queue" "$case_root/state" "$case_root/dev"
	printf '%s\n' jdcloud,re-cs-07 >"$case_root/board"
	printf '%s\n' 512 >"$case_root/sys/block/mmcblk0/queue/logical_block_size"
	printf '%s\n' 240615424 >"$case_root/sys/block/mmcblk0/size"
	: >"$case_root/mounts"
	write_128g_table "$case_root/table"
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
		EMMC_DATA_FAILED_FILE="$case_root/overlay/failed" \
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

# A real legacy p27 may be formatted ext4 but have only the historical GPT
# PARTLABEL=data. The provisioner must leave it intact for UUID migration,
# never attempt a new tail partition or rewrite its filesystem.
CASE_LEGACY="$TMP_ROOT/legacy-p27"
setup_case "$CASE_LEGACY" jdcloud,re-cs-02 4173857
append_reviewed_p27 "$CASE_LEGACY/table"
EMMC_DATA_TEST_FILESYSTEM_TYPE=ext4 EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_LEGACY"

if [ -e "$CASE_LEGACY/state/sgdisk.calls" ] && \
	grep -Eq -- '--backup=|--new=|^-e( |$)' "$CASE_LEGACY/state/sgdisk.calls"; then
	echo "healthy legacy p27 reached a GPT mutation path"
	exit 1
fi
[ ! -e "$CASE_LEGACY/state/mkfs.calls" ] || {
	echo "healthy legacy p27 was formatted"
	exit 1
}
[ -f "$CASE_LEGACY/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "healthy legacy p27 was not approved for UUID migration"
	exit 1
}

# A reviewed legacy data partition can use a different GPT number. The
# provisioner derives that number from the sole GPT name match rather than
# assuming /dev/mmcblk0p27, then writes it into the approval record.
CASE_LEGACY_ALT="$TMP_ROOT/legacy-alt-number"
setup_case "$CASE_LEGACY_ALT" jdcloud,re-cs-07 4173857
append_reviewed_p27 "$CASE_LEGACY_ALT/table" 28
EMMC_DATA_TEST_FILESYSTEM_TYPE=ext4 EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_LEGACY_ALT"
grep -Fxq 'number=28' "$CASE_LEGACY_ALT/overlay/.emmc-data-provision.legacy-data-approved" || {
	echo "legacy data partition number was not derived from GPT"
	exit 1
}
[ ! -e "$CASE_LEGACY_ALT/state/mkfs.calls" ] || {
	echo "healthy non-p27 legacy data partition was formatted"
	exit 1
}

CASE_LEGACY_BAD_TYPE="$TMP_ROOT/legacy-p27-bad-gpt-type"
setup_case "$CASE_LEGACY_BAD_TYPE" jdcloud,re-cs-02 4173857
append_reviewed_p27 "$CASE_LEGACY_BAD_TYPE/table"
EMMC_DATA_TEST_FILESYSTEM_TYPE=ext4 EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_PARTITION_TYPE=FFFF \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_LEGACY_BAD_TYPE"
[ ! -e "$CASE_LEGACY_BAD_TYPE/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "legacy p27 with an unreviewed GPT type was approved"
	exit 1
}
[ ! -e "$CASE_LEGACY_BAD_TYPE/state/mkfs.calls" ] || {
	echo "legacy p27 with an unreviewed GPT type was formatted"
	exit 1
}

# A completely raw reviewed p27 is the one repairable case: it is initialized
# once as ext4/openwrt-data. A non-ext4/f2fs filesystem is ambiguous and must
# remain untouched.
CASE_RAW="$TMP_ROOT/raw-p27"
setup_case "$CASE_RAW" jdcloud,re-cs-07 4173857
append_reviewed_p27 "$CASE_RAW/table"
EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_PARTITION_TYPE=8300 run_fixture "$CASE_RAW"
grep -Fq -- '-F -L openwrt-data' "$CASE_RAW/state/mkfs.calls" || {
	echo "raw reviewed p27 was not initialized"
	exit 1
}

CASE_UNKNOWN_FS="$TMP_ROOT/unknown-p27-filesystem"
setup_case "$CASE_UNKNOWN_FS" jdcloud,re-ss-01 4173857
append_reviewed_p27 "$CASE_UNKNOWN_FS/table"
EMMC_DATA_TEST_FILESYSTEM_TYPE=xfs EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNKNOWN_FS"
if [ -e "$CASE_UNKNOWN_FS/state/sgdisk.calls" ] && \
	grep -Eq -- '--backup=|--new=|^-e( |$)' "$CASE_UNKNOWN_FS/state/sgdisk.calls"; then
	echo "unknown legacy filesystem reached a GPT mutation path"
	exit 1
fi
[ ! -e "$CASE_UNKNOWN_FS/state/mkfs.calls" ] || {
	echo "unknown legacy filesystem was reformatted"
	exit 1
}

# A hung mkfs is not retried automatically. The provisioner records a local
# failure marker and exits successfully so uci-defaults does not schedule a
# destructive repeat on every reboot or sysupgrade.
CASE_TIMEOUT="$TMP_ROOT/raw-p27-timeout"
setup_case "$CASE_TIMEOUT" jdcloud,re-ss-01 4173857
append_reviewed_p27 "$CASE_TIMEOUT/table"
EMMC_DATA_TEST_FORMAT_TIMEOUT=1 EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_TIMEOUT"
grep -Fxq 'reason=mkfs-timeout' "$CASE_TIMEOUT/overlay/failed" || {
	echo "timed-out p27 initialization was not recorded as non-retryable"
	exit 1
}
[ ! -e "$CASE_TIMEOUT/state/mkfs.calls" ] || {
	echo "timed-out p27 initialization continued formatting"
	exit 1
}
EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_PARTITION_TYPE=8300 run_fixture "$CASE_TIMEOUT"
[ ! -e "$CASE_TIMEOUT/state/mkfs.calls" ] || {
	echo "timed-out p27 initialization retried on a later boot"
	exit 1
}

# The same deadline handling also applies to a newly-created tail partition.
# Its exact pending marker remains for diagnosis, while the failed marker
# blocks any automatic formatter retry on later boot.
CASE_NEW_TIMEOUT="$TMP_ROOT/new-p27-timeout"
setup_case "$CASE_NEW_TIMEOUT" jdcloud,re-cs-02 4173857
EMMC_DATA_TEST_FORMAT_TIMEOUT=1 EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_DEVICE_READY=1 EMMC_DATA_TEST_NEW_PARTITION_APPEARS=1 \
	run_fixture "$CASE_NEW_TIMEOUT"
grep -Fxq 'reason=mkfs-timeout' "$CASE_NEW_TIMEOUT/overlay/failed" || {
	echo "timed-out new partition initialization was not recorded"
	exit 1
}
[ -f "$CASE_NEW_TIMEOUT/overlay/pending" ] || {
	echo "timed-out new partition lost its exact pending geometry record"
	exit 1
}
[ ! -e "$CASE_NEW_TIMEOUT/state/mkfs.calls" ] || {
	echo "timed-out new partition initialization continued formatting"
	exit 1
}

# A GPT read/probe failure or a tail p27 that begins after an unexpected gap
# is ambiguous. Neither condition may reach mkfs.
CASE_BLKID_FAILURE="$TMP_ROOT/p27-blkid-failure"
setup_case "$CASE_BLKID_FAILURE" jdcloud,re-ss-01 4173857
append_reviewed_p27 "$CASE_BLKID_FAILURE/table"
if EMMC_DATA_TEST_BLKID_FAILURE=1 EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_BLKID_FAILURE"; then
	echo "blkid probe failure was treated as a raw partition"
	exit 1
fi
[ ! -e "$CASE_BLKID_FAILURE/state/mkfs.calls" ] || {
	echo "blkid probe failure formatted p27"
	exit 1
}

CASE_GAPPED="$TMP_ROOT/p27-gapped"
setup_case "$CASE_GAPPED" jdcloud,re-cs-07 4173857
printf '%s\n' '  27         4177920        15269854   5.3 GiB    8300  data' >>"$CASE_GAPPED/table"
if EMMC_DATA_TEST_START=4177920 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_INFO_NAME=data \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_GAPPED"; then
	echo "gapped raw legacy p27 should have been rejected (non-zero)"
	exit 1
fi
[ ! -e "$CASE_GAPPED/state/mkfs.calls" ] || {
	echo "gapped legacy p27 was formatted"
	exit 1
}

# The timeout test uses an exec-style long-running mkfs stand-in. The 1s
# deadline must terminate that real child quickly, not merely a parent shell.
CASE_REAL_TIMEOUT="$TMP_ROOT/p27-real-timeout"
setup_case "$CASE_REAL_TIMEOUT" jdcloud,re-ss-01 4173857
append_reviewed_p27 "$CASE_REAL_TIMEOUT/table"
timeout_started="$(date +%s)"
EMMC_DATA_INIT_TIMEOUT_SECONDS=1 EMMC_DATA_TEST_MKFS_SLEEP=5 \
	EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_INFO_NAME=data \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_REAL_TIMEOUT"
timeout_elapsed=$(( $(date +%s) - timeout_started ))
[ "$timeout_elapsed" -lt 4 ] || {
	echo "mkfs deadline did not terminate the exec child promptly"
	exit 1
}
grep -Fxq 'reason=mkfs-timeout' "$CASE_REAL_TIMEOUT/overlay/failed" || {
	echo "real mkfs timeout was not persisted"
	exit 1
}

# --- Unnamed large data partition (128GB re-cs-07 p24) tests ---

# A raw empty-named 8300 tail partition (128GB re-cs-07 p24) is adopted
# and formatted once. No GPT mutation (no -e/--new/--backup) may occur.
CASE_UNNAMED_RAW="$TMP_ROOT/unnamed-raw-128g"
setup_128g_case "$CASE_UNNAMED_RAW"
EMMC_DATA_TEST_INFO_NAME= EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_FSTAB_FILE="$CASE_UNNAMED_RAW/fstab" \
	run_fixture "$CASE_UNNAMED_RAW"
grep -Fq -- '-F -L openwrt-data' "$CASE_UNNAMED_RAW/state/mkfs.calls" || {
	echo "raw unnamed p24 was not initialized"
	exit 1
}
if [ -e "$CASE_UNNAMED_RAW/state/sgdisk.calls" ] && \
	grep -Eq -- '--backup=|--new=|^-e( |$)' "$CASE_UNNAMED_RAW/state/sgdisk.calls"; then
	echo "unnamed p24 adoption reached a GPT mutation path"
	exit 1
fi
[ -f "$CASE_UNNAMED_RAW/fstab" ] || {
	echo "raw unnamed p24 did not persist fstab mount config"
	exit 1
}
grep -Fxq 'uuid=legacy-uuid' "$CASE_UNNAMED_RAW/fstab" || {
	echo "raw unnamed p24 fstab does not carry the filesystem UUID"
	exit 1
}
[ -f "$CASE_UNNAMED_RAW/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "raw unnamed p24 was not approved for mount"
	exit 1
}

# An existing ext4 on an unnamed tail partition is preserved: no mkfs,
# fstab + approval are written so 99-auto-mount-data can mount by UUID.
CASE_UNNAMED_EXT4="$TMP_ROOT/unnamed-ext4-preserve"
setup_128g_case "$CASE_UNNAMED_EXT4"
EMMC_DATA_TEST_FILESYSTEM_TYPE=ext4 EMMC_DATA_TEST_INFO_NAME= \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_FSTAB_FILE="$CASE_UNNAMED_EXT4/fstab" \
	run_fixture "$CASE_UNNAMED_EXT4"
[ ! -e "$CASE_UNNAMED_EXT4/state/mkfs.calls" ] || {
	echo "healthy ext4 on unnamed p24 was reformatted"
	exit 1
}
[ -f "$CASE_UNNAMED_EXT4/fstab" ] || {
	echo "ext4 unnamed p24 did not persist fstab mount config"
	exit 1
}
grep -Fxq 'fstype=ext4' "$CASE_UNNAMED_EXT4/fstab" || {
	echo "ext4 unnamed p24 fstab does not carry ext4 type"
	exit 1
}
[ -f "$CASE_UNNAMED_EXT4/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "ext4 unnamed p24 was not approved for mount"
	exit 1
}

# An existing f2fs on an unnamed tail partition is likewise preserved.
CASE_UNNAMED_F2FS="$TMP_ROOT/unnamed-f2fs-preserve"
setup_128g_case "$CASE_UNNAMED_F2FS"
EMMC_DATA_TEST_FILESYSTEM_TYPE=f2fs EMMC_DATA_TEST_INFO_NAME= \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_FSTAB_FILE="$CASE_UNNAMED_F2FS/fstab" \
	run_fixture "$CASE_UNNAMED_F2FS"
[ ! -e "$CASE_UNNAMED_F2FS/state/mkfs.calls" ] || {
	echo "healthy f2fs on unnamed p24 was reformatted"
	exit 1
}
grep -Fxq 'fstype=f2fs' "$CASE_UNNAMED_F2FS/fstab" || {
	echo "f2fs unnamed p24 fstab does not carry f2fs type"
	exit 1
}

# Multiple unnamed 8300 partitions meeting the size threshold must be
# rejected: automatic selection is ambiguous and unsafe.
CASE_UNNAMED_MULTI="$TMP_ROOT/unnamed-multiple"
mkdir -p "$CASE_UNNAMED_MULTI/sys/block/mmcblk0/queue" "$CASE_UNNAMED_MULTI/state" "$CASE_UNNAMED_MULTI/dev"
printf '%s\n' jdcloud,re-cs-07 >"$CASE_UNNAMED_MULTI/board"
printf '%s\n' 512 >"$CASE_UNNAMED_MULTI/sys/block/mmcblk0/queue/logical_block_size"
printf '%s\n' 240615424 >"$CASE_UNNAMED_MULTI/sys/block/mmcblk0/size"
: >"$CASE_UNNAMED_MULTI/mounts"
printf '%s\n' \
	'Disk /dev/mmcblk0: 240615424 sectors, 114.7 GiB' \
	'Partition table holds up to 28 entries' \
	'First usable sector is 34, last usable sector is 240615416' \
	'Number  Start (sector)    End (sector)  Size       Code  Name' \
	'  18           53282         4247137   2.0 GiB    FFFF  rootfs' \
	'  22         4247138         4288101   20.0 MiB   FFFF  rootfs_data' \
	'  23         4289126         8484897   2.0 GiB    8300' \
	'  24         8484898       240613375   110.6 GiB  8300' >"$CASE_UNNAMED_MULTI/table"
EMMC_DATA_TEST_INFO_NAME= EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_MULTI"
[ ! -e "$CASE_UNNAMED_MULTI/state/mkfs.calls" ] || {
	echo "multiple unnamed candidates were not rejected"
	exit 1
}

# A filesystem probe failure on an unnamed candidate is ambiguous and must
# never authorise mkfs.
CASE_UNNAMED_BLKID="$TMP_ROOT/unnamed-blkid-failure"
setup_128g_case "$CASE_UNNAMED_BLKID"
if EMMC_DATA_TEST_BLKID_FAILURE=1 EMMC_DATA_TEST_INFO_NAME= \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_BLKID"; then
	echo "blkid probe failure on unnamed p24 was treated as a raw partition"
	exit 1
fi
[ ! -e "$CASE_UNNAMED_BLKID/state/mkfs.calls" ] || {
	echo "blkid probe failure formatted unnamed p24"
	exit 1
}

# An unnamed partition below the minimum size is not adopted; the script
# falls through to tail allocation (which fails here with no tail space).
CASE_UNNAMED_SMALL="$TMP_ROOT/unnamed-too-small"
mkdir -p "$CASE_UNNAMED_SMALL/sys/block/mmcblk0/queue" "$CASE_UNNAMED_SMALL/state" "$CASE_UNNAMED_SMALL/dev"
printf '%s\n' jdcloud,re-cs-07 >"$CASE_UNNAMED_SMALL/board"
printf '%s\n' 512 >"$CASE_UNNAMED_SMALL/sys/block/mmcblk0/queue/logical_block_size"
printf '%s\n' 5000000 >"$CASE_UNNAMED_SMALL/sys/block/mmcblk0/size"
: >"$CASE_UNNAMED_SMALL/mounts"
printf '%s\n' \
	'Disk /dev/mmcblk0: 5000000 sectors, 2.4 GiB' \
	'Partition table holds up to 28 entries' \
	'First usable sector is 34, last usable sector is 4999966' \
	'Number  Start (sector)    End (sector)  Size       Code  Name' \
	'  18           53282         4247137   2.0 GiB    FFFF  rootfs' \
	'  22         4247138         4288101   20.0 MiB   FFFF  rootfs_data' \
	'  24         4288102         4999966   347.6 MiB  8300' >"$CASE_UNNAMED_SMALL/table"
if EMMC_DATA_TEST_INFO_NAME= EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4288102 EMMC_DATA_TEST_END=4999966 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_SMALL"; then
	echo "too-small unnamed p24 was unexpectedly adopted"
	exit 1
fi
[ ! -e "$CASE_UNNAMED_SMALL/state/mkfs.calls" ] || {
	echo "too-small unnamed p24 was formatted"
	exit 1
}

# An unnamed 8300 partition that is not at the tail of the table is left
# untouched; automatic adoption requires the reviewed tail geometry.
CASE_UNNAMED_NONTAIL="$TMP_ROOT/unnamed-non-tail"
mkdir -p "$CASE_UNNAMED_NONTAIL/sys/block/mmcblk0/queue" "$CASE_UNNAMED_NONTAIL/state" "$CASE_UNNAMED_NONTAIL/dev"
printf '%s\n' jdcloud,re-cs-07 >"$CASE_UNNAMED_NONTAIL/board"
printf '%s\n' 512 >"$CASE_UNNAMED_NONTAIL/sys/block/mmcblk0/queue/logical_block_size"
printf '%s\n' 240615424 >"$CASE_UNNAMED_NONTAIL/sys/block/mmcblk0/size"
: >"$CASE_UNNAMED_NONTAIL/mounts"
printf '%s\n' \
	'Disk /dev/mmcblk0: 240615424 sectors, 114.7 GiB' \
	'Partition table holds up to 28 entries' \
	'First usable sector is 34, last usable sector is 240615416' \
	'Number  Start (sector)    End (sector)  Size       Code  Name' \
	'  18           53282         4247137   2.0 GiB    FFFF  rootfs' \
	'  22         4247138         4288101   20.0 MiB   FFFF  rootfs_data' \
	'  23         4289126         8484897   2.0 GiB    8300' \
	'  24         8484898       240613375   110.6 GiB  FFFF  reserved' >"$CASE_UNNAMED_NONTAIL/table"
EMMC_DATA_TEST_INFO_NAME= EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4289126 EMMC_DATA_TEST_END=8484897 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_NONTAIL"
[ ! -e "$CASE_UNNAMED_NONTAIL/state/mkfs.calls" ] || {
	echo "non-tail unnamed p23 was formatted"
	exit 1
}

# An unnamed partition with a non-8300 GPT type is refused.
CASE_UNNAMED_BADTYPE="$TMP_ROOT/unnamed-bad-gpt-type"
setup_128g_case "$CASE_UNNAMED_BADTYPE"
EMMC_DATA_TEST_INFO_NAME= EMMC_DATA_TEST_PARTITION_TYPE=FFFF \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_BADTYPE"
[ ! -e "$CASE_UNNAMED_BADTYPE/state/mkfs.calls" ] || {
	echo "unnamed p24 with non-8300 GPT type was formatted"
	exit 1
}

# An unsupported filesystem (e.g. xfs) on an unnamed tail partition is left
# untouched; only ext4/f2fs may be preserved.
CASE_UNNAMED_UNKNOWNFS="$TMP_ROOT/unnamed-unknown-fs"
setup_128g_case "$CASE_UNNAMED_UNKNOWNFS"
EMMC_DATA_TEST_FILESYSTEM_TYPE=xfs EMMC_DATA_TEST_INFO_NAME= \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_UNKNOWNFS"
[ ! -e "$CASE_UNNAMED_UNKNOWNFS/state/mkfs.calls" ] || {
	echo "xfs on unnamed p24 was reformatted"
	exit 1
}
[ ! -f "$CASE_UNNAMED_UNKNOWNFS/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "xfs on unnamed p24 was approved for mount"
	exit 1
}

# A hung mkfs on an unnamed raw partition is recorded as non-retryable.
CASE_UNNAMED_TIMEOUT="$TMP_ROOT/unnamed-raw-timeout"
setup_128g_case "$CASE_UNNAMED_TIMEOUT"
EMMC_DATA_TEST_FORMAT_TIMEOUT=1 EMMC_DATA_TEST_INFO_NAME= \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_TIMEOUT"
grep -Fxq 'reason=mkfs-timeout' "$CASE_UNNAMED_TIMEOUT/overlay/failed" || {
	echo "timed-out unnamed p24 initialization was not recorded as non-retryable"
	exit 1
}
EMMC_DATA_TEST_INFO_NAME= EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_TIMEOUT"
[ ! -e "$CASE_UNNAMED_TIMEOUT/state/mkfs.calls" ] || {
	echo "timed-out unnamed p24 initialization retried on a later boot"
	exit 1
}

# Idempotency: after a successful unnamed p24 adoption, a second run must
# skip everything because approved_data_exists finds LABEL=openwrt-data.
CASE_UNNAMED_IDEMPOTENT="$TMP_ROOT/unnamed-idempotent"
setup_128g_case "$CASE_UNNAMED_IDEMPOTENT"
EMMC_DATA_TEST_INFO_NAME= EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_FSTAB_FILE="$CASE_UNNAMED_IDEMPOTENT/fstab" \
	run_fixture "$CASE_UNNAMED_IDEMPOTENT"
grep -Fq -- '-F -L openwrt-data' "$CASE_UNNAMED_IDEMPOTENT/state/mkfs.calls" || {
	echo "first-run unnamed p24 was not initialized"
	exit 1
}
# Second run: the formatted marker makes filesystem_type return ext4 and
# approved_data_exists returns true, so no further mkfs should occur.
: >"$CASE_UNNAMED_IDEMPOTENT/state/mkfs.calls"
EMMC_DATA_TEST_EXISTING_DATA=1 EMMC_DATA_TEST_INFO_NAME= \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=240613375 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_UNNAMED_IDEMPOTENT"
[ ! -s "$CASE_UNNAMED_IDEMPOTENT/state/mkfs.calls" ] || {
	echo "second run reformatted an already-approved unnamed p24"
	exit 1
}


# ============================================================================
# Dynamic discovery + geometry relaxation tests
# Covers re-ss-01 (aligned, LABEL=openwrt-data), re-cs-02 (misaligned,
# PARTLABEL=data ext4), re-cs-07 (unnamed raw p24) layouts.
# ============================================================================

# --- re-cs-02: existing ext4 PARTLABEL=data with MISALIGNED start ---
# Vendor-preinstalled ext4 may start immediately after swap without 1MiB
# padding. The geometry check must SKIP start alignment for existing fs and
# write the approval file so 99 can mount by UUID.
CASE_LEGACY_EXT4_MISALIGNED="$TMP_ROOT/legacy-ext4-misaligned"
setup_case "$CASE_LEGACY_EXT4_MISALIGNED" jdcloud,re-cs-02 5656609
printf '%s\n' '  27         5656610        15269854   4.6 GiB    8300  data' >>"$CASE_LEGACY_EXT4_MISALIGNED/table"
EMMC_DATA_TEST_FILESYSTEM_TYPE=ext4 EMMC_DATA_TEST_START=5656610 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_LEGACY_EXT4_MISALIGNED"
[ ! -e "$CASE_LEGACY_EXT4_MISALIGNED/state/mkfs.calls" ] || {
	echo "misaligned ext4 legacy p27 was reformatted"
	exit 1
}
[ -f "$CASE_LEGACY_EXT4_MISALIGNED/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "misaligned ext4 legacy p27 was not approved for UUID migration"
	exit 1
}
grep -Fxq 'number=27' "$CASE_LEGACY_EXT4_MISALIGNED/overlay/.emmc-data-provision.legacy-data-approved" || {
	echo "misaligned ext4 legacy approval does not carry partition number 27"
	exit 1
}
grep -Fxq 'fstype=ext4' "$CASE_LEGACY_EXT4_MISALIGNED/overlay/.emmc-data-provision.legacy-data-approved" || {
	echo "misaligned ext4 legacy approval does not carry fstype=ext4"
	exit 1
}

# --- Raw PARTLABEL=data with MISALIGNED start must still be strictly rejected ---
# A raw (no filesystem) partition must pass 1MiB start alignment before it
# may be formatted. Misaligned raw -> return non-zero, no mkfs, script
# retained for next-boot retry.
CASE_LEGACY_RAW_MISALIGNED="$TMP_ROOT/legacy-raw-misaligned"
setup_case "$CASE_LEGACY_RAW_MISALIGNED" jdcloud,re-cs-02 5656609
printf '%s\n' '  27         5656610        15269854   4.6 GiB    8300  data' >>"$CASE_LEGACY_RAW_MISALIGNED/table"
if EMMC_DATA_TEST_START=5656610 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_INFO_NAME=data \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 EMMC_DATA_TEST_DEVICE_READY=1 \
	run_fixture "$CASE_LEGACY_RAW_MISALIGNED"; then
	echo "misaligned raw legacy p27 should have been rejected (non-zero)"
	exit 1
fi
[ ! -e "$CASE_LEGACY_RAW_MISALIGNED/state/mkfs.calls" ] || {
	echo "misaligned raw legacy p27 was formatted"
	exit 1
}
[ ! -f "$CASE_LEGACY_RAW_MISALIGNED/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "misaligned raw legacy p27 was incorrectly approved"
	exit 1
}

# --- Geometry failure (not tail partition) returns non-zero ---
# A PARTLABEL=data partition that is not the last partition must be rejected
# with non-zero so the script is retained for retry, not silently deleted.
CASE_LEGACY_NONTAIL="$TMP_ROOT/legacy-nontail"
setup_case "$CASE_LEGACY_NONTAIL" jdcloud,re-cs-02 4173857
printf '%s\n' '  27         4175872         8388607   2.0 GiB    8300  data' >>"$CASE_LEGACY_NONTAIL/table"
printf '%s\n' '  28         8388608        15269854   3.3 GiB    FFFF  vendor_reserved' >>"$CASE_LEGACY_NONTAIL/table"
if EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=8388607 EMMC_DATA_TEST_INFO_NAME=data \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 EMMC_DATA_TEST_DEVICE_READY=1 \
	run_fixture "$CASE_LEGACY_NONTAIL"; then
	echo "non-tail legacy data partition should have been rejected (non-zero)"
	exit 1
fi
[ ! -e "$CASE_LEGACY_NONTAIL/state/mkfs.calls" ] || {
	echo "non-tail legacy data partition was formatted"
	exit 1
}

# --- re-ss-01: existing LABEL=openwrt-data -> no provision action ---
# When approved_data_exists finds LABEL=openwrt-data, 98 must exit early
# without any GPT mutation or mkfs. This is the re-ss-01 steady state.
CASE_RESS01_EXISTING="$TMP_ROOT/resss01-existing-label"
setup_case "$CASE_RESS01_EXISTING" jdcloud,re-ss-01 6271000
printf '%s\n' '  27         6273024        15269854   4.3 GiB    8300  openwrt-data' >>"$CASE_RESS01_EXISTING/table"
EMMC_DATA_TEST_EXISTING_DATA=1 EMMC_DATA_TEST_START=6273024 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_INFO_NAME=openwrt-data EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_RESS01_EXISTING"
[ ! -e "$CASE_RESS01_EXISTING/state/sgdisk.calls" ] && [ ! -e "$CASE_RESS01_EXISTING/state/mkfs.calls" ] || {
	echo "re-ss-01 existing LABEL=openwrt-data triggered provision action"
	exit 1
}

# ============================================================================
# Adopt function (handle_existing_unnamed_data_partition) generalization tests
# ============================================================================

# Helper: write a table with a non-tail data candidate followed by a vendor
# partition at the true tail. Used for adopt non-tail tests.
write_nontail_adopt_table() {
	local path="$1" name="${2:-data}" fstype="${3:-}"
	printf '%s\n' \
		'Disk /dev/mmcblk0: 240615424 sectors, 114.7 GiB' \
		'Partition table holds up to 28 entries' \
		'First usable sector is 34, last usable sector is 240615416' \
		'Number  Start (sector)    End (sector)  Size       Code  Name' \
		'  18           53282         4247137   2.0 GiB    FFFF  rootfs' \
		'  22         4247138         4288101   20.0 MiB   FFFF  rootfs_data' \
		"  24         4429824         8484897   2.0 GiB    8300  $name" \
		'  25         8484898       240613375   110.6 GiB  FFFF  vendor_reserved' >"$path"
}

# --- adopt: existing ext4 + PARTLABEL=data + NON-TAIL -> preserve ---
# An existing ext4/f2fs is strong evidence; it must be preserved even if not
# at the tail (vendor may reserve partitions after data).
CASE_ADOPT_EXT4_NONTAIL="$TMP_ROOT/adopt-ext4-nontail"
mkdir -p "$CASE_ADOPT_EXT4_NONTAIL/sys/block/mmcblk0/queue" "$CASE_ADOPT_EXT4_NONTAIL/state" "$CASE_ADOPT_EXT4_NONTAIL/dev"
printf '%s\n' jdcloud,re-cs-07 >"$CASE_ADOPT_EXT4_NONTAIL/board"
printf '%s\n' 512 >"$CASE_ADOPT_EXT4_NONTAIL/sys/block/mmcblk0/queue/logical_block_size"
printf '%s\n' 240615424 >"$CASE_ADOPT_EXT4_NONTAIL/sys/block/mmcblk0/size"
: >"$CASE_ADOPT_EXT4_NONTAIL/mounts"
write_nontail_adopt_table "$CASE_ADOPT_EXT4_NONTAIL/table" data
EMMC_DATA_TEST_FILESYSTEM_TYPE=ext4 EMMC_DATA_TEST_INFO_NAME=data \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=8484897 \
	EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_FSTAB_FILE="$CASE_ADOPT_EXT4_NONTAIL/fstab" \
	run_fixture "$CASE_ADOPT_EXT4_NONTAIL"
[ ! -e "$CASE_ADOPT_EXT4_NONTAIL/state/mkfs.calls" ] || {
	echo "adopt non-tail ext4 was reformatted"
	exit 1
}
[ -f "$CASE_ADOPT_EXT4_NONTAIL/fstab" ] || {
	echo "adopt non-tail ext4 did not persist fstab"
	exit 1
}
[ -f "$CASE_ADOPT_EXT4_NONTAIL/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "adopt non-tail ext4 was not approved"
	exit 1
}

# --- adopt: raw + NON-TAIL -> still rejected ---
# A raw partition must be at the tail before it may be formatted.
CASE_ADOPT_RAW_NONTAIL="$TMP_ROOT/adopt-raw-nontail"
mkdir -p "$CASE_ADOPT_RAW_NONTAIL/sys/block/mmcblk0/queue" "$CASE_ADOPT_RAW_NONTAIL/state" "$CASE_ADOPT_RAW_NONTAIL/dev"
printf '%s\n' jdcloud,re-cs-07 >"$CASE_ADOPT_RAW_NONTAIL/board"
printf '%s\n' 512 >"$CASE_ADOPT_RAW_NONTAIL/sys/block/mmcblk0/queue/logical_block_size"
printf '%s\n' 240615424 >"$CASE_ADOPT_RAW_NONTAIL/sys/block/mmcblk0/size"
: >"$CASE_ADOPT_RAW_NONTAIL/mounts"
write_nontail_adopt_table "$CASE_ADOPT_RAW_NONTAIL/table" data
if EMMC_DATA_TEST_INFO_NAME=data EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4429824 EMMC_DATA_TEST_END=8484897 \
	EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_ADOPT_RAW_NONTAIL"; then
	echo "adopt non-tail raw should have been rejected (non-zero)"
	exit 1
fi
[ ! -e "$CASE_ADOPT_RAW_NONTAIL/state/mkfs.calls" ] || {
	echo "adopt non-tail raw was formatted"
	exit 1
}
[ ! -f "$CASE_ADOPT_RAW_NONTAIL/overlay/.emmc-data-provision.legacy-data-approved" ] || {
	echo "adopt non-tail raw was incorrectly approved"
	exit 1
}

# --- adopt: name=openwrt-data raw + tail + unique -> mkfs ---
# The adopt name matching must include "openwrt-data" (not just empty/data).
CASE_ADOPT_OPENWRTNAME_RAW="$TMP_ROOT/adopt-openwrtname-raw"
mkdir -p "$CASE_ADOPT_OPENWRTNAME_RAW/sys/block/mmcblk0/queue" "$CASE_ADOPT_OPENWRTNAME_RAW/state" "$CASE_ADOPT_OPENWRTNAME_RAW/dev"
printf '%s\n' jdcloud,re-ss-01 >"$CASE_ADOPT_OPENWRTNAME_RAW/board"
printf '%s\n' 512 >"$CASE_ADOPT_OPENWRTNAME_RAW/sys/block/mmcblk0/queue/logical_block_size"
printf '%s\n' 15269888 >"$CASE_ADOPT_OPENWRTNAME_RAW/sys/block/mmcblk0/size"
: >"$CASE_ADOPT_OPENWRTNAME_RAW/mounts"
printf '%s\n' \
	'Disk /dev/mmcblk0: 15269888 sectors, 7.3 GiB' \
	'Partition table holds up to 28 entries' \
	'First usable sector is 34, last usable sector is 15269854' \
	'Number  Start (sector)    End (sector)  Size       Code  Name' \
	'  18           53282         2150433   1024.0 MiB FFFF  rootfs' \
	'  22         2289698         2330657   20.0 MiB   FFFF  rootfs_data' \
	'  27         4175872        15269854   5.3 GiB    8300  openwrt-data' >"$CASE_ADOPT_OPENWRTNAME_RAW/table"
EMMC_DATA_TEST_INFO_NAME=openwrt-data EMMC_DATA_TEST_PARTITION_TYPE=8300 \
	EMMC_DATA_TEST_START=4175872 EMMC_DATA_TEST_END=15269854 \
	EMMC_DATA_TEST_DEVICE_READY=1 \
	EMMC_DATA_TEST_FSTAB_FILE="$CASE_ADOPT_OPENWRTNAME_RAW/fstab" \
	run_fixture "$CASE_ADOPT_OPENWRTNAME_RAW"
grep -Fq -- '-F -L openwrt-data' "$CASE_ADOPT_OPENWRTNAME_RAW/state/mkfs.calls" || {
	echo "adopt name=openwrt-data raw tail partition was not initialized"
	exit 1
}
[ -f "$CASE_ADOPT_OPENWRTNAME_RAW/fstab" ] || {
	echo "adopt openwrt-name raw did not persist fstab"
	exit 1
}

# --- adopt: name matching covers all three (empty, data, openwrt-data) ---
# Verify the script source includes all three name patterns in the adopt awk.
grep -Fq '$4 == "" || $4 == "data" || $4 == "openwrt-data"' "$SCRIPT" || {
	echo "adopt function does not match empty/data/openwrt-data names"
	exit 1
}

echo "guarded eMMC data provisioning tests passed"
