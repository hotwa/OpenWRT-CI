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
EMMC_DATA_TEST_START=4177920 EMMC_DATA_TEST_END=15269854 EMMC_DATA_TEST_INFO_NAME=data \
	EMMC_DATA_TEST_PARTITION_TYPE=8300 EMMC_DATA_TEST_DEVICE_READY=1 run_fixture "$CASE_GAPPED"
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

echo "guarded eMMC data provisioning tests passed"
