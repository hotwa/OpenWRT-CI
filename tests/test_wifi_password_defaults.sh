#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT_DIR/Scripts/Settings.sh"

[ -f "$SETTINGS" ] || { echo "missing Settings.sh"; exit 1; }

if git -C "$ROOT_DIR" grep -n 'WRT_WORD' -- .github/workflows >/dev/null; then
	echo "workflow YAML must not override the upstream Wi-Fi password"
	exit 1
fi

if grep -Eq "BASE_WORD=|s/key='\.\*'/key=" "$SETTINGS"; then
	echo "Settings.sh must not override the upstream Wi-Fi password"
	exit 1
fi

TEST_ROOT="$(mktemp -d)"
WORK_DIR="$TEST_ROOT/wrt"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p \
	"$WORK_DIR/feeds/luci/collections/theme" \
	"$WORK_DIR/feeds/luci/modules/luci-mod-system/htdocs" \
	"$WORK_DIR/feeds/luci/modules/luci-mod-status/htdocs" \
	"$WORK_DIR/package/base-files/files/bin" \
	"$WORK_DIR/package/network/config/wifi-scripts/files/lib/wifi" \
	"$WORK_DIR/package/emortal/default-settings/files" \
	"$TEST_ROOT/patches"

printf '%s\n' 'DEPENDS:=+luci-theme-bootstrap' >"$WORK_DIR/feeds/luci/collections/theme/Makefile"
printf '%s\n' 'const ip = "192.168.1.1";' >"$WORK_DIR/feeds/luci/modules/luci-mod-system/htdocs/flash.js"
printf '%s\n' "return (luciversion || '');" >"$WORK_DIR/feeds/luci/modules/luci-mod-status/htdocs/10_system.js"
printf '%s\n' "hostname='OpenWrt'" 'lan_ip=192.168.1.1' >"$WORK_DIR/package/base-files/files/bin/config_generate"
printf '%s\n' 'mirror.nju.edu.cn/immortalwrt' >"$WORK_DIR/package/emortal/default-settings/files/99-default-settings-chinese"
printf '%s\n' 'placeholder patch' >"$TEST_ROOT/patches/001-fix_compile_with_ccache.patch"
cat >"$WORK_DIR/package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc" <<'EOF'
ssid='upstream-ssid'
key='upstream-password'
country='US'
encryption='psk2'
EOF

(
	cd "$WORK_DIR"
	WRT_THEME=argon WRT_IP=192.168.12.1 WRT_DATE=2026-08-29 WRT_SSID=mesh-ssid \
		bash "$SETTINGS"
)

grep -Fq "key='upstream-password'" "$WORK_DIR/package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc" || {
	echo "Settings.sh changed the upstream Wi-Fi password"
	exit 1
}

echo "Wi-Fi password default tests passed"
