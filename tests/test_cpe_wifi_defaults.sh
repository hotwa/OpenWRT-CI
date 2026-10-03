#!/usr/bin/env bash
set -euo pipefail
trap 'printf "%s: fixture failed at line %s\n" "${BASH_SOURCE[0]##*/}" "$LINENO" >&2' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$ROOT_DIR/Scripts/ConfigureCpeWifi.sh"
REAL_STAT="$(command -v stat)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/overlay" "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/invalid"
export WRT_CPE_5G=true WRT_ENCRYPT_ARTIFACT=true WRT_REQUIRED_DEVICE=jdcloud_re-ss-01
# This fake credential exercises shell and UCI metacharacters without using a
# real password. No value is embedded in the generated helper or defaults.
export CPE_WIFI_PASSWORD="fixture'quote\" dollar\$ semi; slash\\ end"
"$ROOT_DIR/Scripts/ConfigureCpe5G.sh" "$WORK_DIR/overlay" true >/dev/null

reject_build() {
	if "$GENERATOR" "$WORK_DIR/invalid" true >"$WORK_DIR/build.log" 2>&1; then
		echo 'unsafe CPE WiFi build input unexpectedly succeeded' >&2; exit 1
	fi
	[ ! -e "$WORK_DIR/invalid/etc/cpe5g/wifi.key" ]
}
reject_build # The gated CPE overlay is mandatory.
"$ROOT_DIR/Scripts/ConfigureCpe5G.sh" "$WORK_DIR/invalid" true >/dev/null
(unset CPE_WIFI_PASSWORD; reject_build)
(export CPE_WIFI_PASSWORD=short; reject_build)
(export CPE_WIFI_PASSWORD=$'fixture\ninvalid'; reject_build)
(export CPE_WIFI_PASSWORD=$'fixture\tinvalid'; reject_build)
(export CPE_WIFI_PASSWORD='fixture-中文'; reject_build)
(export CPE_WIFI_PASSWORD="$(printf '%064d' 0)"; reject_build)
(export WRT_CPE_5G=false; reject_build)
(export WRT_ENCRYPT_ARTIFACT=false; reject_build)
(export WRT_REQUIRED_DEVICE=jdcloud_re-cs-02; reject_build)
if grep -Fq "$CPE_WIFI_PASSWORD" "$WORK_DIR/build.log"; then echo 'build error leaked WiFi key' >&2; exit 1; fi

"$GENERATOR" "$WORK_DIR/overlay" true >"$WORK_DIR/build.log"
HELPER="$WORK_DIR/overlay/usr/libexec/cpe5g-wifi-reconcile"
KEY="$WORK_DIR/overlay/etc/cpe5g/wifi.key"
[ "$(stat -c %a "$KEY")" = 600 ] && [ "$(stat -c %a "$(dirname "$KEY")")" = 700 ]
[ "$(cat "$KEY")" = "$CPE_WIFI_PASSWORD" ]
for file in "$HELPER" "$WORK_DIR/overlay/etc/init.d/cpe5g-wifi-reconcile" "$WORK_DIR/overlay/etc/uci-defaults/95-cpe-5g-wifi"; do
	[ -x "$file" ]; sh -n "$file"
	if grep -Fq "$CPE_WIFI_PASSWORD" "$file"; then echo 'private key leaked into executable preset' >&2; exit 1; fi
done
grep -Fq 'CPE5G_RECONCILE_BIN=/usr/libexec/cpe5g-wifi-reconcile' "$WORK_DIR/overlay/etc/init.d/cpe5g-wifi-reconcile"
grep -Fq '/usr/libexec/cpe5g-mwan3-gated-reconcile' "$WORK_DIR/overlay/etc/init.d/cpe5g-wifi-reconcile"
bash "$ROOT_DIR/Scripts/PrivateFirmwareGuard.sh" "$WORK_DIR/overlay" >"$WORK_DIR/private.env" 2>"$WORK_DIR/private.log"
grep -Fxq WRT_PRIVATE_BUILD=true "$WORK_DIR/private.env"
grep -Fq cpe-wifi-credential "$WORK_DIR/private.env"
if grep -Fq "$CPE_WIFI_PASSWORD" "$WORK_DIR/private.env" "$WORK_DIR/private.log" "$WORK_DIR/build.log"; then echo 'guard leaked WiFi key' >&2; exit 1; fi

cat >"$WORK_DIR/bin/uci" <<'PY'
#!/usr/bin/env python3
import json, os, shlex, sys
from pathlib import Path
a = sys.argv[1:]
delta = None
no_commit = False
while a and a[0].startswith('-'):
    option = a.pop(0)
    if option == '-q': continue
    if option in ('-P', '-t'):
        delta = Path(a.pop(0)) / 'wireless-delta.json'
        if option == '-P': no_commit = True
        continue
    raise SystemExit(2)
state = Path(os.environ['TEST_UCI_STATE'])
data = json.loads(state.read_text())
pending = json.loads(delta.read_text()) if delta and delta.exists() else {}
for name, value in pending.items():
    if value is None: data.pop(name, None)
    else: data[name] = value
op = a.pop(0)
arg = a[0] if a else ''
def record(message):
    with open(os.environ['TEST_UCI_LOG'], 'a') as f: f.write(message + '\n')
def stage(name, value):
    if not delta: raise SystemExit(2)
    pending[name] = value
    delta.write_text(json.dumps(pending))
    record(('delete ' if value is None else 'set ') + name)
if op == 'get':
    if arg not in data: raise SystemExit(1)
    print(data[arg])
elif op == 'show':
    if os.environ.get('TEST_DELAY_RADIOS') == '1' and not delta:
        counter = Path(os.environ['TEST_SHOW_COUNTER'])
        count = int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(count + 1))
        if count < 2: raise SystemExit(0)
    for k, v in data.items():
        if k == arg or k.startswith(arg + '.'):
            print(k + '=' + (v if k.count('.') == 1 else repr(v)))
elif op == 'batch':
    for line in sys.stdin:
        parts = shlex.split(line, comments=False, posix=True)
        if len(parts) != 2 or parts[0] != 'set': raise SystemExit(2)
        name, value = parts[1].split('=', 1)
        if os.environ.get('TEST_STAGE_FAIL') == name: raise SystemExit(1)
        if os.environ.get('TEST_BATCH_SILENT_FAIL') == name: continue
        stage(name, value)
elif op == 'delete':
    if arg not in data: raise SystemExit(1)
    stage(arg, None)
elif op == 'commit':
    record('commit ' + arg)
    # The actual UCI CLI treats -P commit as a successful no-op.
    if no_commit: raise SystemExit(0)
    if os.environ.get('TEST_COMMIT_FAIL') == '1': raise SystemExit(1)
    state.write_text(json.dumps(data))
    if delta and delta.exists(): delta.unlink()
else: raise SystemExit(2)
PY
cat >"$WORK_DIR/bin/wifi" <<'SH'
#!/bin/sh
printf 'wifi %s\n' "$*" >>"$TEST_UCI_LOG"
[ "${TEST_RELOAD_FAIL:-0}" != 1 ]
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_LOGGER_LOG"
SH
cat >"$WORK_DIR/bin/sleep" <<'SH'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$TEST_UCI_LOG"
SH
cat >"$WORK_DIR/bin/stat" <<'SH'
#!/bin/sh
set -eu
# Firmware files are root-owned on the device, but CI fixtures are created by
# the runner user. Model only the UID of these two exact fixture paths; keep
# real permissions, existence checks, and every other stat operation intact.
if [ "$#" -eq 3 ] && [ "$1" = -c ]; then
	uid=''
	if [ "$3" = "$TEST_WIFI_KEY_FIXTURE" ]; then uid="${TEST_WIFI_KEY_UID:-0}"; fi
	if [ "$3" = "$TEST_WIFI_CONFIG_FIXTURE" ]; then uid="${TEST_WIFI_CONFIG_UID:-0}"; fi
	if [ -n "$uid" ]; then
		case "$2" in
			%u) "$TEST_REAL_STAT" -c %u "$3" >/dev/null; printf '%s\n' "$uid"; exit 0 ;;
			%a:%u) mode="$("$TEST_REAL_STAT" -c %a "$3")"; printf '%s:%s\n' "$mode" "$uid"; exit 0 ;;
		esac
	fi
fi
exec "$TEST_REAL_STAT" "$@"
SH
chmod 755 "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH" TEST_UCI_STATE="$WORK_DIR/state.json" TEST_UCI_LOG="$WORK_DIR/uci.log" TEST_LOGGER_LOG="$WORK_DIR/logger.log"
export TEST_REAL_STAT="$REAL_STAT" TEST_WIFI_KEY_FIXTURE="$KEY" TEST_WIFI_CONFIG_FIXTURE="$TEST_UCI_STATE"
export TEST_SHOW_COUNTER="$WORK_DIR/show.counter"
export CPE5G_WIFI_KEY_FILE="$KEY" CPE5G_WIFI_BOARD_FILE="$WORK_DIR/board" CPE5G_WIFI_RUN_DIR="$WORK_DIR/run" CPE5G_WIFI_BIN="$WORK_DIR/bin/wifi"
export CPE5G_WIFI_CONFIG_FILE="$TEST_UCI_STATE"
export CPE5G_WIFI_MAX_ATTEMPTS=3 CPE5G_WIFI_INTERVAL=0 CPE5G_WRTBAK_GATE_FILE="$WORK_DIR/gate.json"
printf '%s\n' jdcloud,re-ss-01 >"$WORK_DIR/board"
[ "$(stat -c %u "$WORK_DIR/board")" = "$("$REAL_STAT" -c %u "$WORK_DIR/board")" ]

reset_fixture() {
	: >"$TEST_UCI_LOG"; : >"$TEST_LOGGER_LOG"
	rm -f "$TEST_SHOW_COUNTER" "$CPE5G_WRTBAK_GATE_FILE"
	rm -f "$CPE5G_WIFI_RUN_DIR/cpe5g-wifi-reload.pending"
	python3 - <<'PY'
import json, os
d = {
 'network.lan': 'interface',
 'wireless.radio0': 'wifi-device', 'wireless.radio0.band': '5g', 'wireless.radio0.htmode': 'HE80', 'wireless.radio0.channel': '149', 'wireless.radio0.disabled': '0',
 'wireless.radio7': 'wifi-device', 'wireless.radio7.band': '2g', 'wireless.radio7.htmode': 'HE20', 'wireless.radio7.channel': '11', 'wireless.radio7.disabled': '1', 'wireless.radio7.require_mode': '11ax',
 'wireless.default_radio0': 'wifi-iface', 'wireless.default_radio0.device': 'radio0', 'wireless.default_radio0.mode': 'ap', 'wireless.default_radio0.network': 'lan', 'wireless.default_radio0.ssid': 'CPE-5G', 'wireless.default_radio0.disabled': '0',
 'wireless.default_radio7': 'wifi-iface', 'wireless.default_radio7.device': 'radio7', 'wireless.default_radio7.mode': 'ap', 'wireless.default_radio7.network': 'lan', 'wireless.default_radio7.ssid': 'CPE-5G', 'wireless.default_radio7.disabled': '0',
 'wireless.user_ap': 'wifi-iface', 'wireless.user_ap.device': 'radio0', 'wireless.user_ap.mode': 'ap', 'wireless.user_ap.network': 'lan', 'wireless.user_ap.ssid': 'existing-five', 'wireless.user_ap.key': 'fixture-user-key',
 'wireless.iot_custom': 'wifi-iface', 'wireless.iot_custom.device': 'radio7', 'wireless.iot_custom.ssid': 'existing-iot', 'wireless.iot_custom.disabled': '0',
}
with open(os.environ['TEST_UCI_STATE'], 'w') as f: json.dump(d, f)
PY
	chmod 644 "$TEST_UCI_STATE"
}
reject_runtime() {
	if sh "$HELPER" >"$WORK_DIR/runtime.out" 2>"$WORK_DIR/runtime.err"; then
		echo 'unsafe CPE WiFi runtime input unexpectedly succeeded' >&2; exit 1
	fi
	! grep -q '^wifi ' "$TEST_UCI_LOG"
	[ -z "$(find "$CPE5G_WIFI_RUN_DIR" -mindepth 1 -print -quit)" ]
}
reset_fixture
TEST_DELAY_RADIOS=1 sh "$HELPER" >"$WORK_DIR/runtime.out" 2>"$WORK_DIR/runtime.err"
[ "$(stat -c %a "$CPE5G_WIFI_CONFIG_FILE")" = 600 ]
[ "$(grep -c '^sleep ' "$TEST_UCI_LOG")" -eq 2 ]
python3 - <<'PY'
import json, os
d = json.load(open(os.environ['TEST_UCI_STATE']))
expected = {'device':'radio7', 'mode':'ap', 'network':'lan', 'ssid':'CPE-s13-IoT', 'encryption':'psk2+ccmp', 'key':os.environ['CPE_WIFI_PASSWORD'], 'ieee80211w':'0', 'ieee80211r':'0', 'wps_pushbutton':'0', 'hidden':'0', 'isolate':'0', 'wmm':'1', 'disabled':'0'}
assert d['wireless.cpe5g_iot'] == 'wifi-iface'
for k, v in expected.items(): assert d['wireless.cpe5g_iot.'+k] == v, k
for k, v in {'band':'2g','channel':'1','htmode':'HT20','country':'CN','disabled':'0','cell_density':'0','legacy_rates':'1'}.items(): assert d['wireless.radio7.'+k] == v, k
assert 'wireless.radio7.require_mode' not in d
assert d['wireless.default_radio7.disabled'] == d['wireless.default_radio0.disabled'] == '1'
assert d['wireless.radio0.htmode'] == 'HE80' and d['wireless.radio0.channel'] == '149'
assert d['wireless.user_ap.key'] == 'fixture-user-key' and d['wireless.user_ap.ssid'] == 'existing-five'
assert d['wireless.iot_custom.ssid'] == 'existing-iot' and d['wireless.iot_custom.disabled'] == '0'
PY
[ "$(grep -c '^commit wireless$' "$TEST_UCI_LOG")" -eq 1 ]
[ "$(grep -c '^wifi reload$' "$TEST_UCI_LOG")" -eq 1 ]
[ -z "$(find "$CPE5G_WIFI_RUN_DIR" -mindepth 1 -print -quit)" ]
if grep -Fq "$CPE_WIFI_PASSWORD" "$TEST_UCI_LOG" "$TEST_LOGGER_LOG" "$WORK_DIR/runtime.out" "$WORK_DIR/runtime.err"; then echo 'WiFi reconcile leaked key' >&2; exit 1; fi
: >"$TEST_UCI_LOG"
chmod 644 "$CPE5G_WIFI_CONFIG_FILE"
sh "$HELPER"
[ ! -s "$TEST_UCI_LOG" ] || { echo 'WiFi reconcile was not idempotent' >&2; exit 1; }
[ "$(stat -c %a "$CPE5G_WIFI_CONFIG_FILE")" = 600 ]

# Legacy band identification is supported; a modified stock-looking 5 GHz AP
# remains owned by the user and must not be disabled.
reset_fixture
python3 - <<'PY'
import json, os
p=os.environ['TEST_UCI_STATE']; d=json.load(open(p)); del d['wireless.radio7.band']; d['wireless.radio7.hwmode']='11g'; d['wireless.default_radio0.ssid']='my-five'; json.dump(d,open(p,'w'))
PY
sh "$HELPER"
python3 - <<'PY'
import json, os
d=json.load(open(os.environ['TEST_UCI_STATE'])); assert d['wireless.cpe5g_iot.device']=='radio7'; assert d['wireless.default_radio0.disabled']=='0'
PY

# Board, missing/ambiguous radio, restore gate, and root-only credential checks
# must all reject without persisting a partial wireless configuration.
reset_fixture
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
printf '%s\n' jdcloud,re-cs-02 >"$WORK_DIR/board"
reject_runtime; cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"
[ "$(stat -c %a "$CPE5G_WIFI_CONFIG_FILE")" = 644 ]
printf '%s\n' jdcloud,re-ss-01 >"$WORK_DIR/board"
reset_fixture
python3 - <<'PY'
import json, os
p=os.environ['TEST_UCI_STATE']; d=json.load(open(p)); d['wireless.radio7.band']='5g'; json.dump(d,open(p,'w'))
PY
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
reject_runtime; cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"
[ "$(grep -c '^sleep ' "$TEST_UCI_LOG")" -eq 2 ]
reset_fixture
python3 - <<'PY'
import json, os
p=os.environ['TEST_UCI_STATE']; d=json.load(open(p)); d['wireless.radio9']='wifi-device'; d['wireless.radio9.band']='2g'; json.dump(d,open(p,'w'))
PY
reject_runtime
reset_fixture
python3 - <<'PY'
import json, os
p=os.environ['TEST_UCI_STATE']; d=json.load(open(p)); d['wrtbak.main.firstboot_auto_enabled']='1'; json.dump(d,open(p,'w'))
PY
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
printf '%s\n' '{"state":"restoring"}' >"$CPE5G_WRTBAK_GATE_FILE"
reject_runtime; cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"
[ "$(stat -c %a "$CPE5G_WIFI_CONFIG_FILE")" = 644 ]
printf '%s\n' '{"state":"restored"}' >"$CPE5G_WRTBAK_GATE_FILE"
sh "$HELPER"
reset_fixture
chmod 644 "$KEY"
reject_runtime
chmod 600 "$KEY"

# The root view is limited to fixture paths, and the live root ownership
# checks must still reject each private file independently for any runner UID.
reset_fixture
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
(export TEST_WIFI_KEY_UID=1001; reject_runtime)
cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"
[ "$(stat -c %a "$CPE5G_WIFI_CONFIG_FILE")" = 644 ]
grep -Fq 'root-only IoT WiFi credential is unavailable' "$TEST_LOGGER_LOG"
reset_fixture
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
(export TEST_WIFI_CONFIG_UID=1001; reject_runtime)
cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"
[ "$(stat -c %a "$CPE5G_WIFI_CONFIG_FILE")" = 644 ]
grep -Fq 'root-owned wireless configuration is unavailable' "$TEST_LOGGER_LOG"

# Staged changes are discarded on batch or commit failure. Neither path may
# reload WiFi with incomplete settings or leave the private delta directory.
reset_fixture
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
(export TEST_STAGE_FAIL=wireless.cpe5g_iot.key; reject_runtime)
cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"
reset_fixture
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
(export TEST_BATCH_SILENT_FAIL=wireless.cpe5g_iot.key; reject_runtime)
cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"
[ "$(grep -c '^set wireless.cpe5g_iot.key$' "$TEST_UCI_LOG" || true)" -eq 0 ]

# A reload failure persists its obligation even though config was committed.
# On retry, an otherwise idempotent invocation reloads without another commit.
reset_fixture
if TEST_RELOAD_FAIL=1 sh "$HELPER" >"$WORK_DIR/runtime.out" 2>"$WORK_DIR/runtime.err"; then
	echo 'failed WiFi reload unexpectedly succeeded' >&2; exit 1
fi
[ "$(grep -c '^wifi reload$' "$TEST_UCI_LOG")" -eq 3 ]
[ -f "$CPE5G_WIFI_RUN_DIR/cpe5g-wifi-reload.pending" ]
[ "$(stat -c %a "$CPE5G_WIFI_RUN_DIR/cpe5g-wifi-reload.pending")" = 600 ]
: >"$TEST_UCI_LOG"
sh "$HELPER"
[ "$(cat "$TEST_UCI_LOG")" = 'wifi reload' ]
[ -z "$(find "$CPE5G_WIFI_RUN_DIR" -mindepth 1 -print -quit)" ]
reset_fixture
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
(export TEST_COMMIT_FAIL=1; reject_runtime)
cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"

# Confirm the fixture models UCI's -P no-op commit semantics. A regression
# back to -P in the helper would fail the persisted-state assertions above.
reset_fixture
cp "$TEST_UCI_STATE" "$WORK_DIR/before.json"
mkdir "$WORK_DIR/no-commit"
printf "set wireless.radio7.channel='8'\n" | uci -q -P "$WORK_DIR/no-commit" batch
[ "$(uci -q -P "$WORK_DIR/no-commit" get wireless.radio7.channel)" = 8 ]
uci -q -P "$WORK_DIR/no-commit" commit wireless
cmp "$WORK_DIR/before.json" "$TEST_UCI_STATE"

# Reusing this overlay for a disabled/isolation build removes all generated
# private WiFi files and restores public classification for this credential.
"$GENERATOR" "$WORK_DIR/overlay" false
for file in "$KEY" "$HELPER" "$WORK_DIR/overlay/etc/init.d/cpe5g-wifi-reconcile" "$WORK_DIR/overlay/etc/uci-defaults/95-cpe-5g-wifi"; do [ ! -e "$file" ]; done
bash "$ROOT_DIR/Scripts/PrivateFirmwareGuard.sh" "$WORK_DIR/overlay" >"$WORK_DIR/public.env" 2>/dev/null
grep -Fxq WRT_PRIVATE_BUILD=false "$WORK_DIR/public.env"
echo 'CPE private IoT WiFi generator, radio discovery, gate, and reconciliation passed'
