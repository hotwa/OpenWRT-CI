#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
CFST_MAKEFILE="$ROOT_DIR/package/cfst/Makefile"
README="$ROOT_DIR/README.md"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }
[ -f "$CFST_MAKEFILE" ] || { echo "missing cfst package Makefile"; exit 1; }

grep -q '^CF_IP_SPEED_PANEL_COMMIT=09a8020fd7e6603522b47a4af04a0a2e39f2662e$' "$PACKAGES_SH" || {
	echo "Cloudflare IP speed panel source is not pinned to the reviewed commit"
	exit 1
}

grep -q '^UPDATE_PACKAGE "cf-ip-speed-client" "10000ge10000/cf-ip-speed-panel" "main" "pkg" "luci-app-cf-ip-speed-client" "\$CF_IP_SPEED_PANEL_COMMIT"$' "$PACKAGES_SH" || {
	echo "Packages.sh does not extract both Cloudflare IP speed client packages"
	exit 1
}

grep -q 'Cloudflare IP speed client packages were not extracted' "$PACKAGES_SH" || {
	echo "Packages.sh does not validate Cloudflare IP speed package extraction"
	exit 1
}

grep -q '^PKG_VERSION:=2.3.5$' "$CFST_MAKEFILE" || {
	echo "cfst package is not pinned to v2.3.5"
	exit 1
}

grep -q '^PKG_HASH:=0ac992fcf24d4684caed33620deb9b83ce82f32d2418dc1f90be490ce5900300$' "$CFST_MAKEFILE" || {
	echo "cfst package archive hash is missing or changed"
	exit 1
}

grep -q 'PKGARCH:=aarch64_cortex-a53' "$CFST_MAKEFILE" || {
	echo "cfst package is not limited to the reviewed ARM64 target"
	exit 1
}

grep -Fq '$(INSTALL_BIN) $(PKG_BUILD_DIR)/cfst $(1)/usr/bin/cfst' "$CFST_MAKEFILE" || {
	echo "cfst package does not install the expected binary"
	exit 1
}

for config in Config/IPQ60XX-WIFI-NO.txt Config/IPQ60XX-WIFI-YES.txt Config/TEST.txt; do
	config_file="$ROOT_DIR/$config"
	grep -q '^CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=".*cfst .*cf-ip-speed-client .*luci-app-cf-ip-speed-client' "$config_file" || {
		echo "$config does not scope Cloudflare IP speed packages to jdcloud_re-cs-02"
		exit 1
	}
	done

for config in Config/IPQ60XX-WIFI-NO.txt Config/IPQ60XX-WIFI-YES.txt Config/TEST.txt; do
	config_file="$ROOT_DIR/$config"
	if grep -q '^CONFIG_PACKAGE_\(cfst\|cf-ip-speed-client\|luci-app-cf-ip-speed-client\)=[ym]' "$config_file"; then
		echo "$config globally enables Cloudflare IP speed packages"
		exit 1
	fi
	done

grep -q '临时停止 Nikki、DAE、HomeProxy' "$README" || {
	echo "README does not document Cloudflare IP speed proxy interruption"
	exit 1
}

echo "Cloudflare IP speed client guard test passed"
