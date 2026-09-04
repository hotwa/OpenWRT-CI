#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/openwrt-data-storage-diagnose"

test -x "$SCRIPT"
sh -n "$SCRIPT"

grep -Fq 'automatic_action=none' "$SCRIPT"
grep -Fq 'unknown_partition=report evidence and request explicit user confirmation' "$SCRIPT"
grep -Fq 'forbidden_heuristic=selecting the largest, last, userdata, or unlabeled partition' "$SCRIPT"
grep -Fq 'sgdisk -p /dev/mmcblk0' "$SCRIPT"

if grep -Eq '(mkfs\.|sgdisk[[:space:]]+--new|mount[[:space:]]+|uci[[:space:]]+set)' "$SCRIPT"; then
	echo 'storage diagnosis helper must remain read-only' >&2
	exit 1
fi

echo 'openwrt data storage diagnosis guards passed'
