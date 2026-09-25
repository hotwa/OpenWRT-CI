#!/usr/bin/env bash
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
WIFI_PASSWORD="${CPE5G_WIFI_PASSWORD:-}"
DEFAULTS="$TARGET_FILES/etc/uci-defaults/96-cpe5g-wifi"

[ -n "$WIFI_PASSWORD" ] || {
	echo 'ERROR: CPE5G_WIFI_PASSWORD is required for the CPE-5G Wi-Fi profile' >&2
	exit 1
}
printf '%s' "$WIFI_PASSWORD" | LC_ALL=C grep -Eq '^[ -~]{8,63}$' || {
	echo 'ERROR: CPE5G_WIFI_PASSWORD must be 8-63 printable ASCII characters' >&2
	exit 1
}

mkdir -p "$(dirname "$DEFAULTS")"
wifi_password_b64="$(printf '%s' "$WIFI_PASSWORD" | base64 | tr -d '\n')"

umask 077
cat > "$DEFAULTS" <<EOF
#!/bin/sh
set -eu

expected_board='jdcloud,re-ss-01'
actual_board="\$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null || true)"
if [ "\$actual_board" != "\$expected_board" ]; then
	logger -t cpe5g-wifi-defaults 'board mismatch; Wi-Fi defaults skipped'
	exit 0
fi

wifi config >/dev/null 2>&1 || true
radio_2g=''
radio_5g=''
for section in \$(uci -q show wireless | sed -n "s/^wireless\\.\\(radio[0-9][0-9]*\\)=wifi-device$/\\1/p"); do
	band="\$(uci -q get "wireless.\$section.band" 2>/dev/null || true)"
	case "\$band" in
		2g|2.4g) radio_2g="\$section" ;;
		5g|5.8g) radio_5g="\$section" ;;
	esac
done
if [ -z "\$radio_2g" ] || [ -z "\$radio_5g" ]; then
	logger -t cpe5g-wifi-defaults 'required 2.4GHz and 5GHz radios not found; Wi-Fi defaults skipped'
	exit 0
fi

wifi_key="\$(printf '%s' '$wifi_password_b64' | base64 -d)"

uci set "wireless.\$radio_2g.country=CN"
uci set "wireless.\$radio_2g.channel=6"
uci set "wireless.\$radio_2g.htmode=HE20"
uci set "wireless.\$radio_2g.legacy_rates=1"
uci set "wireless.\$radio_2g.disabled=0"
uci set "wireless.\$radio_5g.country=CN"
uci set "wireless.\$radio_5g.channel=36"
uci set "wireless.\$radio_5g.htmode=HE80"
uci set "wireless.\$radio_5g.disabled=0"

for section in cpe_iot cpe_wifi6_2g cpe_wifi6_5g; do
	uci -q delete "wireless.\$section" 2>/dev/null || true
done

uci set wireless.cpe_iot='wifi-iface'
uci set wireless.cpe_iot.device="\$radio_2g"
uci set wireless.cpe_iot.mode='ap'
uci set wireless.cpe_iot.network='lan'
uci set wireless.cpe_iot.ssid='CPE-loT'
uci set wireless.cpe_iot.encryption='psk2+ccmp'
uci set wireless.cpe_iot.key="\$wifi_key"
uci set wireless.cpe_iot.ieee80211w='0'

uci set wireless.cpe_wifi6_2g='wifi-iface'
uci set wireless.cpe_wifi6_2g.device="\$radio_2g"
uci set wireless.cpe_wifi6_2g.mode='ap'
uci set wireless.cpe_wifi6_2g.network='lan'
uci set wireless.cpe_wifi6_2g.ssid='CPE-WiFi6-2.4G'
uci set wireless.cpe_wifi6_2g.encryption='psk2+ccmp'
uci set wireless.cpe_wifi6_2g.key="\$wifi_key"
uci set wireless.cpe_wifi6_2g.ieee80211w='0'

uci set wireless.cpe_wifi6_5g='wifi-iface'
uci set wireless.cpe_wifi6_5g.device="\$radio_5g"
uci set wireless.cpe_wifi6_5g.mode='ap'
uci set wireless.cpe_wifi6_5g.network='lan'
uci set wireless.cpe_wifi6_5g.ssid='CPE-WiFi6-5G'
uci set wireless.cpe_wifi6_5g.encryption='psk2+ccmp'
uci set wireless.cpe_wifi6_5g.key="\$wifi_key"
uci set wireless.cpe_wifi6_5g.ieee80211w='0'

uci commit wireless
wifi reload
logger -t cpe5g-wifi-defaults 'CPE-5G Wi-Fi defaults applied'
exit 0
EOF
chmod 0700 "$DEFAULTS"

unset WIFI_PASSWORD wifi_password_b64
echo 'CPE-5G Wi-Fi defaults prepared (credentials redacted)'
