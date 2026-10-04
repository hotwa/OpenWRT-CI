#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/off" "$TMP_DIR/wrong" "$TMP_DIR/on" "$TMP_DIR/bin"
"$ROOT_DIR/Scripts/ConfigureCpeIpv6.sh" "$TMP_DIR/off" false
[ -z "$(find "$TMP_DIR/off" -type f -print -quit)" ]
if "$ROOT_DIR/Scripts/ConfigureCpeIpv6.sh" "$TMP_DIR/wrong" true >/dev/null 2>&1; then
 echo 'IPv6 overlay must require the dedicated CPE overlay' >&2; exit 1
fi
"$ROOT_DIR/Scripts/ConfigureCpe5G.sh" "$TMP_DIR/on" true >/dev/null
"$ROOT_DIR/Scripts/ConfigureCpeIpv6.sh" "$TMP_DIR/on" true >/dev/null
for path in lib/netifd/proto/cpe6.sh usr/sbin/cpe5g-ipv6 usr/libexec/cpe5g-ipv6-reconcile etc/init.d/cpe5g-ipv6-reconcile etc/init.d/cpe6-route-audit-bootstrap etc/uci-defaults/93-cpe-5g-ipv6; do
 [ -x "$TMP_DIR/on/$path" ]; sh -n "$TMP_DIR/on/$path"
done
for module in adb model probe worker audit-bootstrap quota-logger local-failover; do node --check "$TMP_DIR/on/usr/libexec/cpe5g-ipv6/$module.mjs"; done
grep -Fxq ' procd_set_param respawn 3600 5 0' "$TMP_DIR/on/etc/init.d/cpe6-route-audit-bootstrap"
node - "$TMP_DIR/on/www/luci-static/resources/protocol/cpe6.js" <<'JS'
const fs=require('node:fs'),assert=require('node:assert/strict');
const protocol=new Function('network','_',fs.readFileSync(process.argv[2],'utf8'))({
 registerProtocol(name,options){assert.equal(name,'cpe6');return options;}
},value=>value);
assert.equal(protocol.getI18n(),'SIM IPv6 (usb0)');
JS
# Run the custom protocol against helper mocks; validate every configured value.
INCLUDE_ONLY=1 . "$TMP_DIR/on/lib/netifd/proto/cpe6.sh"
proto_config_add_string(){ printf 's:%s\n' "$@"; }
proto_config_add_int(){ printf 'i:%s\n' "$@"; }
registered="$(proto_cpe6_init_config)"
for item in s:host s:lan s:mode i:port i:interval i:lifetime; do grep -Fxq "$item" <<<"$registered"; done
json_get_vars(){ host=192.168.66.1; port=5555; lan=guest; mode=router; interval=30; lifetime=180; }
proto_run_command(){ printf '%s\n' "$@"; }
proto_kill_command(){ printf 'kill:%s\n' "$1"; }
expected=$'cpe6\n/usr/sbin/cpe5g-ipv6\ncpe6\nusb0\n192.168.66.1\n5555\nguest\nrouter\n30\n180'
[ "$(proto_cpe6_setup cpe6 usb0)" = "$expected" ]
[ "$(proto_cpe6_teardown cpe6)" = kill:cpe6 ]
cat >"$TMP_DIR/bin/uci" <<'EOF'
#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
p=Path(os.environ['TEST_UCI_STATE']); d=json.loads(p.read_text()); a=sys.argv[1:]
if a[0]=='-q':a=a[1:]
op=a[0]; key=a[1] if len(a)>1 else ''
def get(k):
 if k not in d:sys.exit(1)
 v=d[k];return ' '.join(v) if isinstance(v,list) else str(v)
if op=='get':print(get(key))
elif op=='show':
 for k,v in d.items():
  if k==key or k.startswith(key+'.'):
   if isinstance(v,list):print(k+'='+ ' '.join("'"+x+"'" for x in v))
   else:print(k+'='+ (str(v) if k.count('.')==1 else "'"+str(v)+"'"))
elif op in ('set','add_list'):
 k,v=key.split('=',1)
 if op=='set':d[k]=v
 else:
  if k not in d:d[k]=[]
  if not isinstance(d[k],list):sys.exit(2)
  d[k].append(v)
elif op=='delete':
 if key not in d:sys.exit(1)
 del d[key]
elif op=='commit':pass
else:sys.exit(2)
if op in ('set','delete','add_list','commit'):
 p.write_text(json.dumps(d));open(os.environ['TEST_UCI_LOG'],'a').write(op+' '+key+'\n')
EOF
cat >"$TMP_DIR/bin/ubus" <<'EOF'
#!/bin/sh
[ "$*" = 'call network reload' ] || exit 1
printf 'network reload\n' >>"$TEST_UCI_LOG"
EOF
cat >"$TMP_DIR/bin/init-mock" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >>"$TEST_UCI_LOG"
EOF
cat >"$TMP_DIR/bin/ifdown" <<'EOF'
#!/bin/sh
printf 'ifdown %s\n' "$*" >>"$TEST_UCI_LOG"
EOF
chmod 755 "$TMP_DIR/bin/"*
export TEST_UCI_STATE="$TMP_DIR/state.json" TEST_UCI_LOG="$TMP_DIR/log" PATH="$TMP_DIR/bin:$PATH"
printf '%s' '{"network.5G":"interface","network.lan":"interface","network.wan.proto":"pppoe","network.wan.password":"fixture-only","dhcp.lan":"dhcp","firewall.@defaults[0]":"defaults","firewall.@defaults[0].flow_offloading":"1","firewall.@defaults[0].flow_offloading_hw":"1","firewall.wan":"zone","firewall.wan.name":"wan","firewall.wan.network":["wan","5G"],"network.lan.ip6class":"local cpe6"}' >"$TEST_UCI_STATE"
# Substitute only absolute init calls, preserving the actual reconcile behavior.
sed "s|/etc/init.d/odhcpd|$TMP_DIR/bin/init-mock odhcpd|; s|/etc/init.d/firewall|$TMP_DIR/bin/init-mock firewall|" "$TMP_DIR/on/usr/libexec/cpe5g-ipv6-reconcile" >"$TMP_DIR/reconcile.sh"
sh "$TMP_DIR/reconcile.sh"
python3 - <<'PYTEST'
import json,os
d=json.load(open(os.environ['TEST_UCI_STATE']))
assert d['network.lan.ip6class']==['local','cpe6']
assert d['network.cpe6.proto']=='cpe6' and d['network.cpe6.device']=='usb0'
assert d['network.5G.ipv6']=='1'
assert d['dhcp.lan.ra']=='server' and d['dhcp.lan.ra_default']=='0'
assert d['dhcp.lan.prefix_filter']=='fc00::/7'
assert d['dhcp.lan.ra_dns']=='0'
assert d['network.wan.proto']=='pppoe' and d['network.wan.password']=='fixture-only'
assert d['firewall.wan.network']==['wan','5G','cpe6']
assert d['firewall.@defaults[0].flow_offloading']=='0'
assert d['firewall.@defaults[0].flow_offloading_hw']=='0'
PYTEST
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
[ ! -s "$TEST_UCI_LOG" ] || { echo 'reconcile must be idempotent'; cat "$TEST_UCI_LOG"; exit 1; }
# A restored DHCP interface can disable shared usb0 IPv6 while the native
# preset remains current. Repairing only this option must reload netifd.
uci set network.5G.ipv6=0
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
[ "$(uci get network.5G.ipv6)" = 1 ]
[ "$(grep -c '^set ' "$TEST_UCI_LOG")" = 1 ]
grep -Fxq 'set network.5G.ipv6=1' "$TEST_UCI_LOG"
grep -Fxq 'network reload' "$TEST_UCI_LOG"
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
[ ! -s "$TEST_UCI_LOG" ] || { echo 'USB IPv6 repair must be idempotent'; cat "$TEST_UCI_LOG"; exit 1; }
# An older restore can re-enable only flow offloading while the rest of the
# managed preset is already current. The options alone must trigger a reload.
uci set 'firewall.@defaults[0].flow_offloading=1'
uci set 'firewall.@defaults[0].flow_offloading_hw=1'
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
[ "$(uci get 'firewall.@defaults[0].flow_offloading')" = 0 ]
[ "$(uci get 'firewall.@defaults[0].flow_offloading_hw')" = 0 ]
[ "$(grep -c '^set ' "$TEST_UCI_LOG")" = 2 ]
grep -Fxq 'init firewall reload' "$TEST_UCI_LOG"
grep -Fxq 'commit firewall' "$TEST_UCI_LOG"
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
[ ! -s "$TEST_UCI_LOG" ] || { echo 'zero offloading must be idempotent'; cat "$TEST_UCI_LOG"; exit 1; }
# A disabled feature must not rewrite global firewall acceleration choices.
uci set 'firewall.@defaults[0].flow_offloading=1'
uci set 'firewall.@defaults[0].flow_offloading_hw=1'
uci set cpe5g_ipv6.main.enabled=0
uci set network.5G.ipv6=0
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
grep -Fxq 'ifdown cpe6' "$TEST_UCI_LOG"
[ "$(uci get network.cpe6.auto)" = 0 ]
[ "$(uci get network.5G.ipv6)" = 0 ]
[ "$(uci get 'firewall.@defaults[0].flow_offloading')" = 1 ]
[ "$(uci get 'firewall.@defaults[0].flow_offloading_hw')" = 1 ]
if grep -Eq '^(set firewall\.|commit firewall$|init firewall reload$)' "$TEST_UCI_LOG"; then
 echo 'disabled IPv6 preset changed global firewall offloading' >&2; exit 1
fi
# Enabling an existing disabled native interface must repair USB IPv6 and
# activate cpe6 in the same committed/reloaded network configuration.
uci set cpe5g_ipv6.main.enabled=1
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
[ "$(uci get network.cpe6.auto)" = 1 ]
[ "$(uci get network.5G.ipv6)" = 1 ]
grep -Fxq 'network reload' "$TEST_UCI_LOG"
: >"$TEST_UCI_LOG"
sh "$TMP_DIR/reconcile.sh"
[ ! -s "$TEST_UCI_LOG" ] || { echo 'native enable transition must be idempotent'; cat "$TEST_UCI_LOG"; exit 1; }
echo 'CPE native IPv6 overlay/protocol/reconcile passed'
