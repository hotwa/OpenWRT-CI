#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTIONS_SH="$ROOT_DIR/Scripts/function.sh"
CONFIG_TEST="$ROOT_DIR/Config/TEST.txt"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"

[ -f "$FUNCTIONS_SH" ] || { echo "missing function.sh"; exit 1; }
[ -f "$CONFIG_TEST" ] || { echo "missing TEST.txt"; exit 1; }
[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }

if grep -q '^UPDATE_PACKAGE "luci-app-athena-led" "NONGFAH/luci-app-athena-led" "main"$' "$PACKAGES_SH"; then
	echo "Packages.sh still fetches the legacy NONGFAH athena LED LuCI package by default"
	exit 1
fi

grep -q '^ATHENA_LED_PACKAGE_COMMIT=a0eae21dc1119a56aaf8633c610af03a92f7493c$' "$PACKAGES_SH" || {
	echo "Packages.sh does not pin unraveloop Athena LED to the reviewed v2.4.0 commit"
	exit 1
}

grep -q '^UPDATE_PACKAGE "athena-led" "unraveloop/JDC-AX6600-Athena-LED-Controller" "v2.4.0" "pkg" "luci-app-athena-led" "\$ATHENA_LED_PACKAGE_COMMIT"$' "$PACKAGES_SH" || {
	echo "Packages.sh does not fetch the split unraveloop athena-led/luci-app-athena-led packages"
	exit 1
}

grep -q '^# UPDATE_PACKAGE "luci-app-athena-led" "NONGFAH/luci-app-athena-led" "main"$' "$PACKAGES_SH" || {
	echo "Packages.sh does not document that the legacy NONGFAH package remains disabled"
	exit 1
}

grep -q '^CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=".*athena-led .*luci-app-athena-led' "$CONFIG_TEST" || {
	echo "TEST config does not keep unraveloop Athena LED scoped to jdcloud_re-cs-02"
	exit 1
}

if grep -q '^CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=".*athena-led' "$CONFIG_TEST"; then
	echo "TEST config installs Athena LED on jdcloud_re-ss-01 instead of only jdcloud_re-cs-02"
	exit 1
fi

if grep -q '^CONFIG_PACKAGE_athena-led=[ym]' "$CONFIG_TEST"; then
	echo "TEST config globally selects athena-led instead of scoping it to jdcloud_re-cs-02"
	exit 1
fi

if grep -q '^CONFIG_PACKAGE_luci-app-athena-led=[ym]' "$CONFIG_TEST"; then
	echo "TEST config globally selects luci-app-athena-led instead of scoping it to jdcloud_re-cs-02"
	exit 1
fi

if grep -q 'luci-i18n-athena-led-zh-cn' "$CONFIG_TEST"; then
	echo "TEST config still references missing standalone athena-led i18n package"
	exit 1
fi

grep -Fq -- "-path '*/athena-led/Makefile'" "$FUNCTIONS_SH" || {
	echo "function.sh does not check whether athena-led core exists before keeping it"
	exit 1
}

grep -Fq -- "-path '*/luci-app-athena-led/Makefile'" "$FUNCTIONS_SH" || {
	echo "function.sh does not check whether luci-app-athena-led UI exists before keeping it"
	exit 1
}

grep -q 'luci-i18n-athena-led-zh-cn' "$FUNCTIONS_SH" || {
	echo "function.sh does not strip the missing standalone athena-led i18n package"
	exit 1
}

echo "athena-led device package guard test passed"
