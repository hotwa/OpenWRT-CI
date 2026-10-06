#!/bin/sh
# Private CPE B-only IoT AP; hardware drivers are selected by the caller config.
set +x
set -eu

[ "$#" -eq 2 ] || { echo 'usage: ConfigureCpeWifi.sh <overlay> <true|false>' >&2; exit 1; }
FILES="$1"
ENABLE="$2"
case "$ENABLE" in true|false) ;; *) echo 'ERROR: invalid CPE WiFi enable input' >&2; exit 1 ;; esac
[ -d "$FILES" ] || { echo 'ERROR: CPE WiFi overlay directory is missing' >&2; exit 1; }

KEY="$FILES/etc/cpe5g/wifi.key"
HELPER="$FILES/usr/libexec/cpe5g-wifi-reconcile"
SERVICE="$FILES/etc/init.d/cpe5g-wifi-reconcile"
DEFAULTS="$FILES/etc/uci-defaults/95-cpe-5g-wifi"
if [ "$ENABLE" = false ]; then
	# An overlay reused for the isolation build must not retain a private preset.
	rm -f "$KEY" "$HELPER" "$SERVICE" "$DEFAULTS"
	exit 0
fi

[ "${WRT_CPE_5G:-false}" = true ] && [ "${WRT_ENCRYPT_ARTIFACT:-false}" = true ] &&
	[ "${WRT_REQUIRED_DEVICE:-}" = jdcloud_re-ss-01 ] || {
	echo 'ERROR: CPE WiFi credentials require a CPE-only encrypted build' >&2
	exit 1
}
[ -x "$FILES/usr/libexec/cpe5g-mwan3-gated-reconcile" ] || {
	echo 'ERROR: CPE WiFi requires the guarded CPE network overlay' >&2
	exit 1
}
password="${CPE_WIFI_PASSWORD:-}"
[ "${#password}" -ge 8 ] && [ "${#password}" -le 63 ] &&
	[ "$(LC_ALL=C printf '%s' "$password" | LC_ALL=C tr -d '\040-\176' | wc -c | tr -d '[:space:]')" -eq 0 ] || {
	echo 'ERROR: CPE WiFi password must contain 8 to 63 printable ASCII characters' >&2
	exit 1
}
umask 077
mkdir -p "$FILES/etc/cpe5g" "$FILES/usr/libexec" "$FILES/etc/init.d" "$FILES/etc/uci-defaults"
[ ! -L "$FILES/etc/cpe5g" ] && [ ! -L "$KEY" ] || {
	echo 'ERROR: CPE WiFi credential destination must not be a symlink' >&2
	exit 1
}
chmod 700 "$FILES/etc/cpe5g"
printf '%s' "$password" >"$KEY"
chmod 600 "$KEY"
unset password CPE_WIFI_PASSWORD

cat >"$HELPER" <<'EOF'
#!/bin/sh
set +x
set -eu

TAG='cpe5g-wifi-reconcile'
KEY_FILE="${CPE5G_WIFI_KEY_FILE:-/etc/cpe5g/wifi.key}"
BOARD_FILE="${CPE5G_WIFI_BOARD_FILE:-/tmp/sysinfo/board_name}"
CONFIG_FILE="${CPE5G_WIFI_CONFIG_FILE:-/etc/config/wireless}"
GATE_FILE="${CPE5G_WRTBAK_GATE_FILE:-/root/wrtbak/firstboot/gate.json}"
MAX_ATTEMPTS="${CPE5G_WIFI_MAX_ATTEMPTS:-60}"
INTERVAL="${CPE5G_WIFI_INTERVAL:-2}"
RUN_DIR="${CPE5G_WIFI_RUN_DIR:-/var/run}"
WIFI="${CPE5G_WIFI_BIN:-/sbin/wifi}"
RELOAD_PENDING="$RUN_DIR/cpe5g-wifi-reload.pending"
DELTA_DIR=''

log() { logger -t "$TAG" "$*" 2>/dev/null || true; }
fail() { log "$1"; exit 1; }
cleanup() { [ -z "$DELTA_DIR" ] || rm -rf "$DELTA_DIR"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(cat "$BOARD_FILE" 2>/dev/null || true)" = 'jdcloud,re-ss-01' ] ||
	fail 'IoT WiFi preset requires a verified RE-SS-01 board'
case "$MAX_ATTEMPTS" in ''|*[!0-9]*) fail 'invalid WiFi retry limit' ;; esac
case "$INTERVAL" in ''|*[!0-9]*) fail 'invalid WiFi retry interval' ;; esac
[ "$MAX_ATTEMPTS" -gt 0 ] && [ "$MAX_ATTEMPTS" -le 120 ] && [ "$INTERVAL" -le 30 ] ||
	fail 'WiFi retry settings exceed the bounded startup window'

# The shared gate wrapper may time out. Never apply this private AP to config
# that a still-running firstboot restore could subsequently replace.
restore_enabled="$(uci -q get wrtbak.main.firstboot_auto_enabled 2>/dev/null || true)"
case "$restore_enabled" in
	1|true|yes|on|enabled)
		state='missing'
		if [ -r "$GATE_FILE" ]; then
			if command -v jsonfilter >/dev/null 2>&1; then
				state="$(jsonfilter -i "$GATE_FILE" -e '@.state' 2>/dev/null || true)"
			else
				state="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GATE_FILE" | sed -n '1p')"
			fi
		fi
		case "$state" in already_done|restored|no_backup|failed_final|disabled) ;; *) fail 'waiting for a terminal wrtbak restore decision' ;; esac
		;;
esac

[ -f "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ] && [ "$(stat -c '%a:%u' "$KEY_FILE" 2>/dev/null || true)" = '600:0' ] ||
	fail 'root-only IoT WiFi credential is unavailable'
key="$(cat "$KEY_FILE")"
bytes="$(wc -c <"$KEY_FILE" | tr -d '[:space:]')"
[ "$bytes" = "${#key}" ] && [ "${#key}" -ge 8 ] && [ "${#key}" -le 63 ] &&
	[ "$(LC_ALL=C printf '%s' "$key" | LC_ALL=C tr -d '\040-\176' | wc -c | tr -d '[:space:]')" -eq 0 ] ||
	fail 'IoT WiFi credential format is invalid'

# Device numbering varies between driver builds. Discover the actual 2.4 GHz
# radio from netifd configuration, after wireless generation has completed.
attempt=0
radio=''
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
	radios=''
	for section in $(uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([A-Za-z0-9_]*\)=wifi-device$/\1/p'); do
		band="$(uci -q get "wireless.$section.band" 2>/dev/null || true)"
		hwmode="$(uci -q get "wireless.$section.hwmode" 2>/dev/null || true)"
		if [ "$band" = '2g' ] || { [ -z "$band" ] && [ "$hwmode" = '11g' ]; }; then
			radios="${radios:+$radios }$section"
		fi
	done
	set -- $radios
	case "$#" in
		1) radio="$1"; break ;;
		0) ;;
		*) fail 'multiple 2.4 GHz radios require explicit device selection' ;;
	esac
	attempt=$((attempt + 1))
	[ "$attempt" -lt "$MAX_ATTEMPTS" ] || break
	sleep "$INTERVAL"
done
[ -n "$radio" ] || fail '2.4 GHz radio was not generated within the startup window'
[ "$(uci -q get network.lan 2>/dev/null || true)" = interface ] || fail 'LAN interface is unavailable'

# UCI preserves a config file's existing mode on commit. Protect the target
# before inserting the PSK, including restored files that were mode 0644.
[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] &&
	[ "$(stat -c %u "$CONFIG_FILE" 2>/dev/null || true)" = 0 ] ||
	fail 'root-owned wireless configuration is unavailable'
chmod 600 "$CONFIG_FILE" || fail 'wireless configuration permissions could not be protected'

umask 077
DELTA_DIR="$(mktemp -d "$RUN_DIR/cpe5g-wifi-uci.XXXXXX")" || fail 'WiFi staging directory is unavailable'
changed=0
get() { uci -q -t "$DELTA_DIR" get "$1" 2>/dev/null || true; }
set_value() {
	name="$1"
	value="$2"
	[ "$(get "$name")" != "$value" ] || return 0
	# UCI batch stdin keeps the private PSK out of process arguments and logs.
	quoted="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
	printf "set %s='%s'\n" "$name" "$quoted" |
		uci -q -t "$DELTA_DIR" batch >/dev/null 2>&1 || fail 'WiFi configuration staging failed'
	# The UCI CLI reports batch success even if an individual command failed.
	# Read back every staged value without logging private values.
	[ "$(get "$name")" = "$value" ] || fail 'WiFi configuration staging readback failed'
	changed=1
}
delete_value() {
	uci -q -t "$DELTA_DIR" get "$1" >/dev/null 2>&1 || return 0
	uci -q -t "$DELTA_DIR" delete "$1" >/dev/null 2>&1 || fail 'WiFi configuration staging failed'
	if uci -q -t "$DELTA_DIR" get "$1" >/dev/null 2>&1; then fail 'WiFi configuration deletion readback failed'; fi
	changed=1
}

# Disable only the untouched upstream AP sections, including a 5 GHz stock
# AP. A changed SSID or a user-added section is outside this preset's ownership.
for section in $(uci -q -t "$DELTA_DIR" show wireless 2>/dev/null | sed -n 's/^wireless\.\([A-Za-z0-9_]*\)=wifi-device$/\1/p'); do
	iface="default_$section"
	[ "$(get "wireless.$iface")" = wifi-iface ] || continue
	[ "$(get "wireless.$iface.device")" = "$section" ] || continue
	[ "$(get "wireless.$iface.mode")" = ap ] || continue
	[ "$(get "wireless.$iface.network")" = lan ] || continue
	ssid="$(get "wireless.$iface.ssid")"
	case "$ssid" in
		CPE-5G)
			set_value "wireless.$iface.disabled" 1
			;;
		*) ;;
	esac
done

set_value "wireless.$radio.band" 2g
set_value "wireless.$radio.channel" 1
set_value "wireless.$radio.htmode" HT20
set_value "wireless.$radio.country" CN
set_value "wireless.$radio.disabled" 0
set_value "wireless.$radio.cell_density" 0
set_value "wireless.$radio.legacy_rates" 1
delete_value "wireless.$radio.require_mode"
set_value wireless.cpe5g_iot wifi-iface
set_value wireless.cpe5g_iot.device "$radio"
set_value wireless.cpe5g_iot.mode ap
set_value wireless.cpe5g_iot.network lan
set_value wireless.cpe5g_iot.ssid CPE-s13-IoT
set_value wireless.cpe5g_iot.encryption psk2+ccmp
set_value wireless.cpe5g_iot.key "$key"
set_value wireless.cpe5g_iot.ieee80211w 0
set_value wireless.cpe5g_iot.ieee80211r 0
set_value wireless.cpe5g_iot.wps_pushbutton 0
set_value wireless.cpe5g_iot.hidden 0
set_value wireless.cpe5g_iot.isolate 0
set_value wireless.cpe5g_iot.wmm 1
set_value wireless.cpe5g_iot.disabled 0
unset key quoted value

if [ "$changed" -eq 1 ]; then
	# Record the reload obligation before commit, including the crash window
	# between a successful commit and starting netifd's WiFi reload.
	[ ! -L "$RELOAD_PENDING" ] || fail 'WiFi reload marker must not be a symlink'
	had_pending=0
	[ ! -f "$RELOAD_PENDING" ] || had_pending=1
	printf '1\n' >"$RELOAD_PENDING" || fail 'WiFi reload marker could not be written'
	# -t selects the savedir while preserving commit. -P intentionally turns
	# commit into a successful no-op in the real UCI CLI and must not be used.
	if ! uci -q -t "$DELTA_DIR" commit wireless >/dev/null 2>&1; then
		[ "$had_pending" -eq 1 ] || rm -f "$RELOAD_PENDING"
		fail 'WiFi configuration commit failed'
	fi
fi
if [ -f "$RELOAD_PENDING" ]; then
	[ ! -L "$RELOAD_PENDING" ] || fail 'WiFi reload marker must not be a symlink'
	attempt=0
	while ! "$WIFI" reload >/dev/null 2>&1; do
		attempt=$((attempt + 1))
		[ "$attempt" -lt 3 ] || fail 'IoT WiFi reload failed; retry is pending'
		sleep 2
	done
	rm -f "$RELOAD_PENDING"
	log 'compatible 2.4 GHz IoT AP configured on LAN'
fi
exit 0
EOF

cat >"$SERVICE" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=98
start_service() {
	procd_open_instance
	procd_set_param command /usr/libexec/cpe5g-mwan3-gated-reconcile
	procd_set_param env CPE5G_RECONCILE_BIN=/usr/libexec/cpe5g-wifi-reconcile
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param term_timeout 5
	procd_close_instance
}
EOF

cat >"$DEFAULTS" <<'EOF'
#!/bin/sh
set -eu
/etc/init.d/cpe5g-wifi-reconcile enable
/etc/init.d/cpe5g-wifi-reconcile start
exit 0
EOF
chmod 755 "$HELPER" "$SERVICE" "$DEFAULTS"
echo 'CPE WiFi: private compatible 2.4 GHz IoT AP staged for guarded first boot'
