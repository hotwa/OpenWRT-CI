#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/94-zram-swap-defaults"

grep -Fxq 'CONFIG_PACKAGE_zram-swap=y' "$GENERAL"
grep -Fxq 'CONFIG_KERNEL_SWAP=y' "$GENERAL"
test -x "$DEFAULTS"

grep -Fq 'zram_size_mb:$zram_size_mb' "$DEFAULTS"
grep -Fq "'zram_comp_algo:lz4'" "$DEFAULTS"
grep -Fq "'zram_priority:100'" "$DEFAULTS"
grep -Fq 'zram_size_mb=256' "$DEFAULTS"
grep -Fq '/etc/init.d/zram enable' "$DEFAULTS"
grep -Fq 'data-runtime fallback' "$DEFAULTS"
if grep -Fq 'zram_size_mb=128' "$DEFAULTS"; then
	echo 'zram defaults must keep the approved universal 256 MiB size' >&2
	exit 1
fi

if grep -Eiq 'mmcblk0p26|/etc/config/fstab|swapon .*mmc|config swap' "$DEFAULTS"; then
	echo 'zram defaults must not enable eMMC swap' >&2
	exit 1
fi

echo 'global zram defaults guard passed'
