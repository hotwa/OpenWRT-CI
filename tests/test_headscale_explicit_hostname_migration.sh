#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$MIGRATION_TEST_TMP"' EXIT
OVERLAY="$MIGRATION_TEST_TMP/overlay"
BIN="$MIGRATION_TEST_TMP/bin"
mkdir -p "$OVERLAY/etc/config" "$BIN"
cp "$ROOT_DIR/files/etc/config/headscale_auto_enroll" "$OVERLAY/etc/config/headscale_auto_enroll"
HEADSCALE_OPENWRT_AUTHKEY='' HEADSCALE_OPENWRT_HOSTNAME=cpe-5g-s13 \
  bash "$ROOT_DIR/Scripts/HeadscaleAutoEnroll.sh" "$OVERLAY" >/dev/null
MIGRATION="$OVERLAY/etc/uci-defaults/93-headscale-explicit-hostname"
[ -x "$MIGRATION" ]; sh -n "$MIGRATION"
[[ "$(basename "$MIGRATION")" < 94-headscale-auto-enroll ]]

export MIGRATION_UCI_STATE="$MIGRATION_TEST_TMP/current.json"
export MIGRATION_UCI_SAVED="$MIGRATION_TEST_TMP/saved.json"
export MIGRATION_UCI_CALLS="$MIGRATION_TEST_TMP/calls"
cat >"$BIN/uci" <<'MOCK'
#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
if args and args[0]=='-q':args=args[1:]
op=args[0];key=args[1] if len(args)>1 else ''
fields={'headscale_auto_enroll.main.'+x for x in ('hostname_mode','hostname_override','hostname_model','hostname_prefix')}
log=Path(os.environ['MIGRATION_UCI_CALLS'])
with log.open('a') as f:f.write(op+' '+key+'\n')
state=Path(os.environ['MIGRATION_UCI_STATE']);saved=Path(os.environ['MIGRATION_UCI_SAVED'])
data=json.loads(state.read_text())
if op=='get' and (key in fields or key=='headscale_auto_enroll.main'):
 if key not in data:sys.exit(1)
 print(data[key])
elif op=='set' and key.split('=',1)[0] in fields:
 field,value=key.split('=',1)
 if os.environ.get('MIGRATION_FAIL_SET')==field:sys.exit(1)
 data[field]=value;state.write_text(json.dumps(data))
elif op=='commit' and key=='headscale_auto_enroll':
 if os.environ.get('MIGRATION_FAIL_COMMIT')=='1':sys.exit(1)
 saved.write_text(json.dumps(data))
else:
 with log.open('a') as f:f.write('FORBIDDEN UCI request\n')
 sys.exit(97)
MOCK
cat >"$BIN/tailscale" <<'MOCK'
#!/bin/sh
printf 'FORBIDDEN tailscale call\n' >>"$MIGRATION_UCI_CALLS"
exit 98
MOCK
chmod 755 "$BIN/"*
export PATH="$BIN:$PATH"
reset_old_config() {
  python3 - <<'PY'
import json,os
from pathlib import Path
fixture={'headscale_auto_enroll.main':'enroll',
 'headscale_auto_enroll.main.enabled':'1',
 'headscale_auto_enroll.main.hostname_override':'openwrt-cpe-5g-13',
 'headscale_auto_enroll.main.hostname_model':'',
 'headscale_auto_enroll.main.hostname_prefix':'legacy',
 'headscale_auto_enroll.main.login_server':'https://headscale.jmsu.top',
 'headscale_auto_enroll.main.auth_key_file':'/etc/tailscale/headscale.authkey'}
for var in ('MIGRATION_UCI_STATE','MIGRATION_UCI_SAVED'):
 Path(os.environ[var]).write_text(json.dumps(fixture))
Path(os.environ['MIGRATION_UCI_CALLS']).write_text('')
PY
}
check_chosen_config() {
  python3 - <<'PY'
import json,os
from pathlib import Path
for var in ('MIGRATION_UCI_STATE','MIGRATION_UCI_SAVED'):
 data=json.loads(Path(os.environ[var]).read_text());prefix='headscale_auto_enroll.main.'
 assert data[prefix+'hostname_mode']=='explicit'
 assert data[prefix+'hostname_override']=='cpe-5g-s13'
 assert data[prefix+'hostname_model']=='' and data[prefix+'hostname_prefix']==''
 assert data[prefix+'enabled']=='1'
 assert data[prefix+'auth_key_file']=='/etc/tailscale/headscale.authkey'
 assert data[prefix+'login_server']=='https://headscale.jmsu.top'
PY
  ! grep -q 'FORBIDDEN' "$MIGRATION_UCI_CALLS"
}
reset_old_config
sh "$MIGRATION"
check_chosen_config
: >"$MIGRATION_UCI_CALLS"
sh "$MIGRATION"
check_chosen_config
! grep -q '^set ' "$MIGRATION_UCI_CALLS"

# Failed writes keep the one-shot unsuccessful so first boot can retry it.
reset_old_config
if MIGRATION_FAIL_SET=headscale_auto_enroll.main.hostname_mode sh "$MIGRATION"; then
  echo 'failed hostname write must defer migration' >&2; exit 1
fi
! grep -q '^commit ' "$MIGRATION_UCI_CALLS"
sh "$MIGRATION"; check_chosen_config

# A failed commit may leave UCI deltas in RAM: retry must persist even when
# the desired values already appear to match current get responses.
reset_old_config
if MIGRATION_FAIL_COMMIT=1 sh "$MIGRATION"; then
  echo 'failed commit must defer migration' >&2; exit 1
fi
python3 - <<'PY'
import json,os
from pathlib import Path
d=json.loads(Path(os.environ['MIGRATION_UCI_SAVED']).read_text())
assert d['headscale_auto_enroll.main.hostname_override']=='openwrt-cpe-5g-13'
PY
sh "$MIGRATION"; check_chosen_config

# OpenWrt removes successful uci-defaults; no runtime loop owns this choice.
rm "$MIGRATION"
uci set headscale_auto_enroll.main.hostname_override=operator-next-name
uci commit headscale_auto_enroll
[ ! -e "$MIGRATION" ]
[ "$(uci get headscale_auto_enroll.main.hostname_override)" = operator-next-name ]

# Preserve an explicit build prefix as a sanitized public UCI preference.
# The current explicit naming mode still takes its label from override alone.
HEADSCALE_OPENWRT_AUTHKEY='' HEADSCALE_OPENWRT_HOSTNAME=cpe-5g-s13 \
  HEADSCALE_OPENWRT_HOSTNAME_PREFIX='Lab Rescue' \
  bash "$ROOT_DIR/Scripts/HeadscaleAutoEnroll.sh" "$OVERLAY" >/dev/null
grep -Fq "option hostname_prefix 'lab-rescue'" "$OVERLAY/etc/config/headscale_auto_enroll"
reset_old_config
sh "$MIGRATION"
python3 - <<'PY_PREFIX'
import json,os
from pathlib import Path
for var in ('MIGRATION_UCI_STATE','MIGRATION_UCI_SAVED'):
 data=json.loads(Path(os.environ[var]).read_text());prefix='headscale_auto_enroll.main.'
 assert data[prefix+'hostname_prefix']=='lab-rescue'
 assert data[prefix+'hostname_override']=='cpe-5g-s13'
 assert data[prefix+'enabled']=='1'
 assert data[prefix+'auth_key_file']=='/etc/tailscale/headscale.authkey'
PY_PREFIX
! grep -q 'FORBIDDEN' "$MIGRATION_UCI_CALLS"

# Empty hostname retains the prior LAN-derived build behavior and removes
# a previous generated script from a reused CI overlay root.
HEADSCALE_OPENWRT_AUTHKEY='' HEADSCALE_OPENWRT_HOSTNAME=cpe-5g-s13 \
  bash "$ROOT_DIR/Scripts/HeadscaleAutoEnroll.sh" "$OVERLAY" >/dev/null
[ -x "$MIGRATION" ]
HEADSCALE_OPENWRT_AUTHKEY='' HEADSCALE_OPENWRT_HOSTNAME='' \
  bash "$ROOT_DIR/Scripts/HeadscaleAutoEnroll.sh" "$OVERLAY" >/dev/null
[ ! -e "$MIGRATION" ]
grep -Fq "option hostname_mode 'lan-site'" "$OVERLAY/etc/config/headscale_auto_enroll"
echo 'Headscale explicit hostname one-shot migration tests passed'
