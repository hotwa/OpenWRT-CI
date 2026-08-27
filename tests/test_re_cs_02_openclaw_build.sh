#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT_DIR/Config/IPQ60XX-RE-CS-02-OPENCLAW.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/RE-CS-02-OPENCLAW-BUILD.yml"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"

[ -f "$CONFIG" ] || { echo "missing RE-CS-02 OpenClaw config"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing RE-CS-02 OpenClaw workflow"; exit 1; }

grep -qx 'CONFIG_TARGET_qualcommax=y' "$CONFIG"
grep -qx 'CONFIG_TARGET_qualcommax_ipq60xx=y' "$CONFIG"
grep -qx 'CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y' "$CONFIG"
[ "$(grep -Ec '^CONFIG_TARGET_DEVICE_.*=y$' "$CONFIG")" -eq 1 ] || {
	echo "RE-CS-02 OpenClaw config must enable exactly one device"
	exit 1
}
grep -q '^CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=".*ipq-wifi-jdcloud_re-cs-02.*athena-led.*luci-app-athena-led' "$CONFIG"
for setting in CONFIG_ATH11K_MEM_PROFILE_512M=y CONFIG_NSS_FIRMWARE_VERSION_12_2=y CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe=y CONFIG_PACKAGE_kmod-fs-ext4=y CONFIG_PACKAGE_kmod-usb-storage=y; do
	grep -qx "$setting" "$CONFIG"
done
grep -qx 'CONFIG_PACKAGE_luci-app-openclaw=y' "$GENERAL"
if grep -q '^CONFIG_PACKAGE_luci-app-openclaw=y$' "$CONFIG"; then
	echo "OpenClaw must be inherited from GENERAL.txt"
	exit 1
fi

grep -Fq 'name: RE-CS-02 OpenClaw Build Only' "$WORKFLOW"
grep -Fq 'workflow_dispatch:' "$WORKFLOW"
grep -Fq 'uses: ./.github/workflows/WRT-CORE.yml' "$WORKFLOW"
grep -Fq 'secrets: inherit' "$WORKFLOW"
grep -Fq 'WRT_CONFIG: IPQ60XX-RE-CS-02-OPENCLAW' "$WORKFLOW"
grep -Fq 'WRT_COMMIT: a4638cd4389183f1a1fcad0441f491ca11c97757' "$WORKFLOW"
grep -Fq 'WRT_BUILD_ONLY: true' "$WORKFLOW"
grep -Fq 'WRT_SPLIT_DEVICE_ARTIFACTS: false' "$WORKFLOW"
grep -Fq 'WRT_EXPECTED_DEVICE: jdcloud_re-cs-02' "$WORKFLOW"
grep -Fq 'WRT_REQUIRED_DEVICE: jdcloud_re-cs-02' "$WORKFLOW"
grep -Fq "WRTBAK_FIRSTBOOT_AUTO_ENABLED: '0'" "$WORKFLOW"
grep -Fq 'WRTBAK_PROXY_PROFILE: auto' "$WORKFLOW"
grep -Fq 'WRT_IP: 192.168.11.1' "$WORKFLOW"
grep -Fq 'WRT_WORD: asdzxc147369' "$WORKFLOW"

echo "RE-CS-02 OpenClaw build guards passed"
