#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT_DIR/Scripts/Settings.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
STOCK_ENABLED="set \${si}.disabled='0'"
STOCK_DISABLED="set \${si}.disabled='1'"

fixture() {
    local name="$1"
    CASE_ROOT="$TEST_ROOT/$name"
    WORK_DIR="$CASE_ROOT/wrt"
    WIFI_UC="$WORK_DIR/package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    mkdir -p \
        "$WORK_DIR/feeds/luci/collections/theme" \
        "$WORK_DIR/feeds/luci/modules/luci-mod-system/htdocs" \
        "$WORK_DIR/feeds/luci/modules/luci-mod-status/htdocs" \
        "$WORK_DIR/package/base-files/files/bin" \
        "$(dirname "$WIFI_UC")" \
        "$WORK_DIR/package/emortal/default-settings/files" \
        "$WORK_DIR/target/linux/mediatek/filogic/base-files/etc/uci-defaults" \
        "$WORK_DIR/target/linux/qualcommax/base-files/etc/uci-defaults" \
        "$CASE_ROOT/patches"
    printf '%s\n' 'DEPENDS:=+luci-theme-bootstrap' >"$WORK_DIR/feeds/luci/collections/theme/Makefile"
    printf '%s\n' 'const ip = "192.168.1.1";' >"$WORK_DIR/feeds/luci/modules/luci-mod-system/htdocs/flash.js"
    printf '%s\n' "return (luciversion || '');" >"$WORK_DIR/feeds/luci/modules/luci-mod-status/htdocs/10_system.js"
    printf '%s\n' "hostname='OpenWrt'" 'lan_ip=192.168.1.1' >"$WORK_DIR/package/base-files/files/bin/config_generate"
    printf '%s\n' 'mirror.nju.edu.cn/immortalwrt' >"$WORK_DIR/package/emortal/default-settings/files/99-default-settings-chinese"
    printf '%s\n' 'fixture patch' >"$CASE_ROOT/patches/001-fix_compile_with_ccache.patch"
    # The exact interface output from immutable upstream mac80211.uc at
    # 0bad892975fe49fd180f99b414a7f168bb694dd7. Fixture password is not a secret.
    cat >"$WIFI_UC" <<'EOF'
let si = "wireless.default_" + name;
print(`set ${si}=wifi-iface
set ${si}.device='${name}'
set ${si}.network='lan'
set ${si}.mode='ap'
set ${si}.ssid='${defaults?.ssid || 'OWRT'}'
set ${si}.encryption='${defaults?.encryption || 'psk2+ccmp'}'
set ${si}.key='fixture-stock-key'
set ${si}.disabled='0'

`);
EOF
}

run_settings() {
    (
        cd "$WORK_DIR"
        WRT_CPE_WIFI="$1" WRT_THEME=argon WRT_IP=192.168.13.1 \
            WRT_DATE=2026-10-03 WRT_SSID=CPE-5G WRT_NAME=CPE-5G \
            WRT_PACKAGE='' WRT_TARGET='' WRT_CONFIG=IPQ60XX-706-WIFI \
            bash "$SETTINGS"
    ) >"$CASE_ROOT/stdout" 2>"$CASE_ROOT/stderr"
}
reject() {
    if run_settings true; then
        echo "invalid stock AP template was accepted: $CASE_ROOT" >&2
        exit 1
    fi
    grep -Eq 'ERROR:.*(pinned ucode|unexpected CPE stock)' "$CASE_ROOT/stderr"
}

fixture enabled
run_settings true
[ "$(grep -Fxc "$STOCK_DISABLED" "$WIFI_UC")" -eq 1 ]
! grep -Fxq "$STOCK_ENABLED" "$WIFI_UC"
grep -Fq "key='fixture-stock-key'" "$WIFI_UC"
run_settings true
[ "$(grep -Fxc "$STOCK_DISABLED" "$WIFI_UC")" -eq 1 ]
! grep -Fxq "$STOCK_ENABLED" "$WIFI_UC"

fixture ordinary
run_settings false
[ "$(grep -Fxc "$STOCK_ENABLED" "$WIFI_UC")" -eq 1 ]
! grep -Fxq "$STOCK_DISABLED" "$WIFI_UC"
grep -Fq "key='fixture-stock-key'" "$WIFI_UC"

fixture unsupported_shell
printf '%s\n' "BASE_SSID='fixture'" >"$WORK_DIR/target/linux/qualcommax/base-files/etc/uci-defaults/99_set-wireless.sh"
reject

fixture missing_uc
rm "$WIFI_UC"
reject

fixture missing_interface_option
sed -i '/\.disabled=/d' "$WIFI_UC"
reject

fixture duplicate_enabled
printf '%s\n' "$STOCK_ENABLED" >>"$WIFI_UC"
reject

fixture mixed_options
printf '%s\n' "$STOCK_DISABLED" >>"$WIFI_UC"
reject

fixture duplicate_disabled
sed -i '/\.disabled=/d' "$WIFI_UC"
printf '%s\n' "$STOCK_DISABLED" "$STOCK_DISABLED" >>"$WIFI_UC"
reject

fixture already_disabled
sed -i '/\.disabled=/d' "$WIFI_UC"
printf '%s\n' "$STOCK_DISABLED" >>"$WIFI_UC"
run_settings true
[ "$(grep -Fxc "$STOCK_DISABLED" "$WIFI_UC")" -eq 1 ]
! grep -Fxq "$STOCK_ENABLED" "$WIFI_UC"

echo 'CPE stock AP build defaults: disabled before first network start, idempotent, ordinary unchanged, unsupported/corrupt source rejected'
