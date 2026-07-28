#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES="$ROOT_DIR/Scripts/Packages.sh"

[ -f "$PACKAGES" ] || {
	echo "missing Packages.sh"
	exit 1
}

grep -Fq 'VIKING_PACKAGES_COMMIT=14e6823509029e90d8008bef14d2cc4ff663884f' "$PACKAGES" || {
	echo "VIKINGYFY packages source is not pinned to the reviewed revision"
	exit 1
}

grep -Fq 'UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "luci-app-timewol luci-app-wolplus" "$VIKING_PACKAGES_COMMIT"' "$PACKAGES" || {
	echo "VIKINGYFY packages checkout does not use the reviewed revision"
	exit 1
}

grep -Fq "SING_BOX_EXPECTED_VERSION='PKG_VERSION:=1.14.0_beta2'" "$PACKAGES" || {
	echo "sing-box is not guarded at the homeproxy-compatible version"
	exit 1
}

grep -Fq "SING_BOX_EXPECTED_HASH='PKG_HASH:=be7ba1c158bc1410b8f1ca2cb185db13adbad1f78302f521802f0d5c2b905ca9'" "$PACKAGES" || {
	echo "sing-box is not guarded at the reviewed source hash"
	exit 1
}

grep -Fq 'rm -rf ../feeds/packages/net/sing-box ./sing-box' "$PACKAGES" || {
	echo "the incompatible feed sing-box package is not removed"
	exit 1
}

grep -Fq 'mv "$SING_BOX_PACKAGE_DIR" ./sing-box' "$PACKAGES" || {
	echo "the reviewed sing-box package is not promoted into the build"
	exit 1
}

echo "homeproxy and sing-box alignment test passed"
