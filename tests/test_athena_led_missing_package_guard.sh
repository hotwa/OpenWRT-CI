#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTIONS_SH="$ROOT_DIR/Scripts/function.sh"
CONFIG_TEST="$ROOT_DIR/Config/TEST.txt"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
ARTIFACT_GUARD="$ROOT_DIR/Scripts/GuardAthenaLedArtifact.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$FUNCTIONS_SH" ] || { echo "missing function.sh"; exit 1; }
[ -f "$CONFIG_TEST" ] || { echo "missing TEST.txt"; exit 1; }
[ -f "$PACKAGES_SH" ] || { echo "missing Packages.sh"; exit 1; }
[ -f "$ARTIFACT_GUARD" ] || { echo "missing Athena LED artifact guard"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }

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

grep -q 'Device\\/jdcloud_re-cs-02' "$FUNCTIONS_SH" || {
	echo "function.sh does not enforce split Athena LED packages on the formal jdcloud_re-cs-02 image"
	exit 1
}

grep -q 'GuardAthenaLedArtifact.sh' "$WORKFLOW" || {
	echo "formal workflow does not verify the final jdcloud_re-cs-02 manifest"
	exit 1
}

grep -q 'Athena LED core package was not extracted' "$PACKAGES_SH" || {
	echo "Packages.sh does not fail when Athena LED core extraction is incomplete"
	exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p \
	"$tmp_dir/package/athena-led" \
	"$tmp_dir/package/luci-app-athena-led" \
	"$tmp_dir/feeds" \
	"$tmp_dir/target/linux/qualcommax/image" \
	"$tmp_dir/bin/targets"
touch "$tmp_dir/package/athena-led/Makefile"
touch "$tmp_dir/package/luci-app-athena-led/Makefile"

cat > "$tmp_dir/target/linux/qualcommax/image/ipq60xx.mk" <<'EOF'
define Device/jdcloud_re-cs-02
  DEVICE_PACKAGES := ipq-wifi-jdcloud_re-cs-02 luci-app-athena-led
endef
define Device/jdcloud_re-ss-01
  DEVICE_PACKAGES := ipq-wifi-jdcloud_re-ss-01
endef
EOF

cat > "$tmp_dir/.config" <<'EOF'
CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y
EOF

(
	cd "$tmp_dir"
	# shellcheck source=/dev/null
	. "$FUNCTIONS_SH"
	normalize_athena_led_device_packages "$tmp_dir/.config"
)

re_cs_02_block=$(sed -n '/^define Device\/jdcloud_re-cs-02$/,/^endef$/p' "$tmp_dir/target/linux/qualcommax/image/ipq60xx.mk")
[ "$(printf '%s\n' "$re_cs_02_block" | grep -o 'athena-led' | wc -l)" -eq 2 ] || {
	echo "formal jdcloud_re-cs-02 device block does not contain exactly one core and one LuCI package"
	exit 1
}

sed -n '/^define Device\/jdcloud_re-ss-01$/,/^endef$/p' "$tmp_dir/target/linux/qualcommax/image/ipq60xx.mk" |
	grep -q 'athena-led' && {
	echo "Athena LED normalization leaked into jdcloud_re-ss-01"
	exit 1
}

cat > "$tmp_dir/bin/targets/immortalwrt-qualcommax-ipq60xx-jdcloud_re-cs-02.manifest" <<'EOF'
athena-led - 2.4.0-r1
luci-app-athena-led - 2.4.0-r1
EOF

sh "$ARTIFACT_GUARD" "$tmp_dir/.config" "$tmp_dir/bin/targets"

sed -i '/^athena-led - /d' "$tmp_dir/bin/targets/immortalwrt-qualcommax-ipq60xx-jdcloud_re-cs-02.manifest"
if sh "$ARTIFACT_GUARD" "$tmp_dir/.config" "$tmp_dir/bin/targets" >/dev/null 2>&1; then
	echo "artifact guard accepted a jdcloud_re-cs-02 manifest without the Athena LED core"
	exit 1
fi

echo "athena-led device package guard test passed"
