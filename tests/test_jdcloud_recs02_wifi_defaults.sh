#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/99-jdcloud-re-cs-02-wifi-defaults-v2"
CONFIG="$ROOT_DIR/Config/IPQ60XX-RE-CS-02.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -x "$DEFAULTS" ] || {
	echo "missing executable JDCloud RE-CS-02 WiFi defaults overlay"
	exit 1
}

grep -Fq 'jdcloud,re-cs-02' "$DEFAULTS" || {
	echo "WiFi defaults script does not guard on jdcloud,re-cs-02"
	exit 1
}

grep -Fq "uci set wireless.default_radio1.ssid='DAE-WRT-IoT'" "$DEFAULTS"
grep -Fq "uci set wireless.radio1.channel='6'" "$DEFAULTS"
grep -Fq "uci set wireless.radio1.htmode='HT20'" "$DEFAULTS"
grep -Fq "uci set wireless.radio1.legacy_rates='1'" "$DEFAULTS"
grep -Fq "uci set wireless.default_radio1.ieee80211w='0'" "$DEFAULTS"

grep -Fq "uci set wireless.default_radio0.ssid='DAE-WRT-5.8G'" "$DEFAULTS"
grep -Fq "uci set wireless.radio0.channel='149'" "$DEFAULTS"
grep -Fq "uci set wireless.radio0.htmode='HE80'" "$DEFAULTS"

grep -Fq "uci set wireless.default_radio2.ssid='DAE-WRT-5.2G'" "$DEFAULTS"
grep -Fq "uci set wireless.radio2.channel='36'" "$DEFAULTS"
grep -Fq "uci set wireless.radio2.htmode='HE80'" "$DEFAULTS"
! grep -Fq "HE160" "$DEFAULTS"

for package in kmod-ath11k kmod-ath11k-ahb kmod-ath11k-pci wireless-regdb wpad-openssl ath11k-firmware-ipq6018-ddwrt ath11k-firmware-qcn9074-ddwrt; do
	grep -qx "CONFIG_PACKAGE_${package}=y" "$CONFIG"
done

grep -Fq "uci set wireless.default_radio1.key='asdzxc147369'" "$DEFAULTS"
grep -Fq "uci set wireless.default_radio0.key='asdzxc147369'" "$DEFAULTS"
grep -Fq "uci set wireless.default_radio2.key='asdzxc147369'" "$DEFAULTS"
grep -Fq "uci commit wireless" "$DEFAULTS"
grep -Fq "wifi reload" "$DEFAULTS"

grep -Fq 'cp -rf ./files/. ./wrt/files/' "$WORKFLOW" || {
	echo "WRT-CORE does not copy repository files overlay into firmware"
	exit 1
}

echo "JDCloud RE-CS-02 WiFi defaults guard passed"
