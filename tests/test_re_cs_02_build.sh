#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT_DIR/Config/IPQ60XX-RE-CS-02.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/RE-CS-02-BUILD.yml"

for file in "$CONFIG" "$WORKFLOW"; do
  [ -f "$file" ] || { echo "missing $file" >&2; exit 1; }
done
grep -Fxq 'CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y' "$CONFIG"
grep -Fq 'CONFIG_PACKAGE_kmod-fs-ext4=y' "$CONFIG"
grep -Fq 'CONFIG_PACKAGE_kmod-fs-f2fs=y' "$CONFIG"
if grep -Eqi 'openclaw|luci-app-openclaw' "$CONFIG" "$WORKFLOW"; then
  echo "RE-CS-02 build must not include OpenClaw" >&2
  exit 1
fi
for term in 'WRT_CONFIG: IPQ60XX-RE-CS-02' 'WRT_EXPECTED_DEVICE: jdcloud_re-cs-02' 'WRT_REQUIRED_DEVICE: jdcloud_re-cs-02' 'WRT_EMMC_DATA_PROVISIONING: true' 'WRT_BUILD_ONLY: true'; do
  grep -Fq "$term" "$WORKFLOW" || { echo "workflow omits $term" >&2; exit 1; }
done

echo "RE-CS-02 workflow guard passed"
