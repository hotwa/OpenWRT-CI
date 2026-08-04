#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
CFST_MAKEFILE="$ROOT_DIR/package/cfst/Makefile"
README="$ROOT_DIR/README.md"
GENERAL_CONFIG="$ROOT_DIR/Config/GENERAL.txt"
DEFAULTS_PATCH="$ROOT_DIR/patches/cf-ip-speed-client-manual-schedule.patch"

[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }
[ -f "$CFST_MAKEFILE" ] || { echo "missing cfst package Makefile"; exit 1; }
[ -f "$DEFAULTS_PATCH" ] || { echo "missing cf-ip-speed-client defaults patch"; exit 1; }

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

grep -Fq 'patch -d ./cf-ip-speed-client --batch --forward -p1 < "$CF_IP_SPEED_CLIENT_PATCH"' "$PACKAGES_SH" || {
	echo "Packages.sh does not apply the Cloudflare IP speed client defaults patch"
	exit 1
}

grep -q '^PKG_VERSION:=2.3.5$' "$CFST_MAKEFILE" || {
	echo "cfst package is not pinned to v2.3.5"
	exit 1
}

grep -q '^CFST_ASSET:=cfst_linux_arm64$' "$CFST_MAKEFILE" || {
	echo "cfst package ARM64 asset is missing"
	exit 1
}

grep -q '^CFST_HASH:=0ac992fcf24d4684caed33620deb9b83ce82f32d2418dc1f90be490ce5900300$' "$CFST_MAKEFILE" || {
	echo "cfst package ARM64 archive hash is missing or changed"
	exit 1
}

grep -q '^CFST_ASSET:=cfst_linux_amd64$' "$CFST_MAKEFILE" || {
	echo "cfst package x86_64 asset is missing"
	exit 1
}

grep -q '^CFST_HASH:=c4c8fc76b4e1bf2bdb5ced8b765956d82dda7bc4eb59df5c04053f0f7db98d90$' "$CFST_MAKEFILE" || {
	echo "cfst package x86_64 archive hash is missing or changed"
	exit 1
}

grep -q '^  PKGARCH:=\$(ARCH)$' "$CFST_MAKEFILE" || {
	echo "cfst package does not follow the target package architecture"
	exit 1
}

grep -Fq '$(INSTALL_BIN) $(PKG_BUILD_DIR)/cfst $(1)/usr/bin/cfst' "$CFST_MAKEFILE" || {
	echo "cfst package does not install the expected binary"
	exit 1
}

for package in cfst cf-ip-speed-client luci-app-cf-ip-speed-client; do
	grep -q "^CONFIG_PACKAGE_$package=y$" "$GENERAL_CONFIG" || {
		echo "Config/GENERAL.txt does not globally enable $package"
		exit 1
	}
done

if grep -R -q '^CONFIG_TARGET_DEVICE_PACKAGES_.*cfst' "$ROOT_DIR/Config"; then
	echo "Cloudflare IP speed packages must remain global rather than device-scoped"
	exit 1
fi

grep -q "option enabled '1'" "$DEFAULTS_PATCH" || {
	echo "cf-ip-speed-client is not enabled by default"
	exit 1
}

grep -q "option upload_enabled '0'" "$DEFAULTS_PATCH" || {
	echo "cf-ip-speed-client default must not upload before user consent"
	exit 1
}

grep -q "option schedule_mode 'manual'" "$DEFAULTS_PATCH" || {
	echo "cf-ip-speed-client default must use manual scheduling"
	exit 1
}

grep -q 'manual|disabled)' "$DEFAULTS_PATCH" || {
	echo "cf-ip-speed-client patch does not support manual scheduling"
	exit 1
}

grep -Fq '$(LN) ../init.d/cf-ip-speed-client $(1)/etc/rc.d/S95cf-ip-speed-client' "$DEFAULTS_PATCH" || {
	echo "cf-ip-speed-client defaults patch does not enable the init service"
	exit 1
}

grep -q '临时停止 Nikki、DAE、HomeProxy' "$README" || {
	echo "README does not document Cloudflare IP speed proxy interruption"
	exit 1
}

grep -q '所有 Cloudflare 托管域名改写为直连 IP' "$README" || {
	echo "README does not document the Cloudflare DNS override boundary"
	exit 1
}

echo "Cloudflare IP speed client guard test passed"
