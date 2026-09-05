#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/94-zram-swap-defaults"
CORE_WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

grep -Fxq 'CONFIG_PACKAGE_zram-swap=y' "$GENERAL"
grep -Fxq 'CONFIG_KERNEL_SWAP=y' "$GENERAL"
grep -Fxq 'CONFIG_PACKAGE_kmod-zram=y' "$GENERAL"
grep -Fxq 'CONFIG_PACKAGE_kmod-lib-lz4=y' "$GENERAL"
grep -Fxq 'CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y' "$GENERAL"
grep -Fxq 'CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y' "$GENERAL"
test -x "$DEFAULTS"

# A source config line is not enough: `make defconfig` can discard an invalid
# Kconfig selection.  The reusable build workflow must gate the final config.
grep -Fq 'required zram lz4 configuration was dropped by defconfig' "$CORE_WORKFLOW"
for zram_config in \
  CONFIG_PACKAGE_zram-swap=y \
  CONFIG_PACKAGE_kmod-zram=y \
  CONFIG_PACKAGE_kmod-lib-lz4=y \
  CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y \
  CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y; do
	grep -Fq "$zram_config" "$CORE_WORKFLOW"
done

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
