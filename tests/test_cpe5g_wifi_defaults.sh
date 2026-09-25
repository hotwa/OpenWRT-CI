#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'find "$WORK_DIR" -depth -delete' EXIT

TARGET_FILES="$WORK_DIR/files"
MOCK_BIN="$WORK_DIR/bin"
MOCK_LOG="$WORK_DIR/uci.log"
mkdir -p "$TARGET_FILES" "$MOCK_BIN"
TEST_PASSWORD='fixture-only-cpe-wifi-passphrase'
CPE5G_WIFI_PASSWORD="$TEST_PASSWORD" bash "$ROOT_DIR/Scripts/ConfigureCpe5GWifi.sh" "$TARGET_FILES" >/dev/null
DEFAULTS="$TARGET_FILES/etc/uci-defaults/96-cpe5g-wifi"
[ -f "$DEFAULTS" ] && [ "$(stat -c '%a' "$DEFAULTS")" = 700 ]
bash -n "$DEFAULTS"
! grep -Fq "$TEST_PASSWORD" "$DEFAULTS" || {
	echo 'CPE Wi-Fi password was written in plaintext into the overlay' >&2
	exit 1
}
grep -q "ssid='CPE-loT'" "$DEFAULTS"
grep -q "ssid='CPE-WiFi6-2.4G'" "$DEFAULTS"
grep -q "ssid='CPE-WiFi6-5G'" "$DEFAULTS"
grep -q "encryption='psk2+ccmp'" "$DEFAULTS"
grep -q 'htmode=HE20' "$DEFAULTS"
grep -q 'htmode=HE80' "$DEFAULTS"

cat > "$MOCK_BIN/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' '{"board_name":"jdcloud,re-ss-01"}'
EOF
cat > "$MOCK_BIN/jsonfilter" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' "${MOCK_BOARD:-jdcloud,re-ss-01}"
EOF
cat > "$MOCK_BIN/wifi" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$MOCK_BIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$MOCK_BIN/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q show wireless')
		printf '%s\n' 'wireless.radio4=wifi-device' 'wireless.radio7=wifi-device'
		;;
	'-q get wireless.radio4.band') printf '%s\n' 2g ;;
	'-q get wireless.radio7.band') printf '%s\n' 5g ;;
	'-q get '*) exit 1 ;;
	'-q delete '*) exit 0 ;;
	'set '*) printf '%s\n' "$*" >> "$MOCK_LOG" ;;
	commit\ wireless) : ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$MOCK_BIN"/*

PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" sh "$DEFAULTS"
for expected in \
	'set wireless.radio4.htmode=HE20' \
	'set wireless.radio7.htmode=HE80' \
	"set wireless.cpe_iot.device=radio4" \
	"set wireless.cpe_wifi6_2g.device=radio4" \
	"set wireless.cpe_wifi6_5g.device=radio7" \
		"set wireless.cpe_iot.ssid=CPE-loT" \
	"set wireless.cpe_wifi6_2g.ssid=CPE-WiFi6-2.4G" \
	"set wireless.cpe_wifi6_5g.ssid=CPE-WiFi6-5G" \
	"set wireless.cpe_iot.key=$TEST_PASSWORD" \
	'set wireless.cpe_iot.ieee80211w=0'; do
	grep -Fqx -- "$expected" "$MOCK_LOG" || {
		echo 'CPE Wi-Fi defaults did not apply the expected radio/BSS policy' >&2
		exit 1
	}
done

: > "$MOCK_LOG"
if PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" MOCK_BOARD=jdcloud,re-cs-02 sh "$DEFAULTS"; then
	[ ! -s "$MOCK_LOG" ] || {
		echo 'CPE Wi-Fi defaults modified a non-CPE-5G board' >&2
		exit 1
	}
else
	echo 'CPE Wi-Fi defaults failed to skip a non-matching board' >&2
	exit 1
fi

echo 'CPE-5G Wi-Fi defaults test passed'
