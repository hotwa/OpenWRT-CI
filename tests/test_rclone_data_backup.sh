#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/rclone-data-backup"
INIT="$ROOT_DIR/files/etc/init.d/rclone-data-backup"
CONFIG="$ROOT_DIR/files/etc/config/rclone-data-backup"
MANIFEST="$ROOT_DIR/files/etc/rclone-data-backup/include.conf"
DOC="$ROOT_DIR/docs/rclone-data-backup.md"

for file in "$SCRIPT" "$INIT" "$CONFIG" "$MANIFEST" "$DOC"; do [ -f "$file" ] || { echo "missing $file"; exit 1; }; done
sh -n "$SCRIPT"; sh -n "$INIT"
grep -Fq "option enabled '0'" "$CONFIG"
grep -Fq "option retain_successful '3'" "$CONFIG"
grep -Fq 'backup_source /data/smb data/smb' "$SCRIPT"
grep -Fq 'manifest must not repeat /data/smb' "$SCRIPT"
grep -Fq 'rclone copy' "$SCRIPT"
grep -Fq 'rclone purge "$SNAPSHOT_ROOT/$old"' "$SCRIPT"
grep -Fq 'rclone about' "$SCRIPT"
grep -Fq 'active writer' "$SCRIPT"
grep -Fq '/var/run/agent-data-backup.status' "$SCRIPT"
grep -Fq 'status=disabled' "$SCRIPT" || grep -Fq 'status_write disabled' "$SCRIPT"
grep -Fq '$1 ~ /^\/dev\//' "$SCRIPT"
grep -Fq 'is_real_data_mount || return 0' "$SCRIPT"
grep -Fq '0 3 * * *' "$INIT"
grep -Fq 'remove_cron' "$INIT"
grep -Fq 'JITTER" -le 20' "$SCRIPT"
grep -Fq 'CONFIG_PACKAGE_coreutils-timeout=y' "$ROOT_DIR/Config/GENERAL.txt"
if grep -Eq 'rclone[[:space:]]+(mount|sync|delete)([[:space:]]|$)' "$SCRIPT"; then echo 'unsafe rclone command found'; exit 1; fi
if grep -Ev '^[[:space:]]*(#|$)' "$CONFIG" "$MANIFEST" | grep -Eiq 'password|token|secret|access_key'; then echo 'credential material found'; exit 1; fi

echo 'rclone data backup guards passed'
