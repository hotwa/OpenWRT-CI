#!/bin/sh
# CPE B-only, native cellular /64 sharing; no kernel or modem firmware changes.
set -eu
[ "$#" = 2 ] || { echo 'usage: ConfigureCpeIpv6.sh <overlay> <true|false>' >&2; exit 1; }
FILES="$1"; ENABLE="$2"
case "$ENABLE" in true|false) ;; *) exit 1;; esac
[ -d "$FILES" ] || exit 1
[ "$ENABLE" = true ] || exit 0
[ -x "$FILES/usr/libexec/cpe5g-mwan3-gated-reconcile" ] || { echo 'CPE IPv6 requires the CPE-only network overlay' >&2; exit 1; }
SOURCE="$(CDPATH= cd -- "$(dirname "$0")/cpe5g-ipv6" && pwd)"
mkdir -p "$FILES/usr/libexec/cpe5g-ipv6" "$FILES/lib/netifd/proto" "$FILES/usr/sbin" "$FILES/etc/init.d" "$FILES/etc/uci-defaults" "$FILES/etc/config" "$FILES/www/luci-static/resources/protocol"
for module in adb model probe worker audit-bootstrap quota-logger local-failover; do cp "$SOURCE/$module.mjs" "$FILES/usr/libexec/cpe5g-ipv6/$module.mjs"; done
cp "$SOURCE/proto.sh" "$FILES/lib/netifd/proto/cpe6.sh"
cp "$SOURCE/reconcile.sh" "$FILES/usr/libexec/cpe5g-ipv6-reconcile"
cat > "$FILES/www/luci-static/resources/protocol/cpe6.js" <<'EOF'
'use strict';
'require network';

// This is the native IPv6 companion of 5G/usb0, not another WAN uplink.
return network.registerProtocol('cpe6', {
 getI18n: function() { return _('SIM IPv6 (usb0)'); },
 renderFormOptions: function() {}
});
EOF
cat > "$FILES/etc/config/cpe5g_ipv6" <<'EOF'
config native 'main'
 option enabled '1'
 option mode 'lan'
 option host '192.168.66.1'
 option port '5555'
 option device 'usb0'
 option lan 'lan'
 option interval '15'
 option lifetime '180'
EOF
cat > "$FILES/usr/sbin/cpe5g-ipv6" <<'EOF'
#!/bin/sh
set -eu
[ -r /etc/profile.d/20-node-agent.sh ] && . /etc/profile.d/20-node-agent.sh
command -v node >/dev/null 2>&1 || { logger -t cpe5g-ipv6 'baked Node runtime unavailable'; exit 1; }
exec node /usr/libexec/cpe5g-ipv6/worker.mjs "$@"
EOF
cat > "$FILES/etc/init.d/cpe5g-ipv6-reconcile" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=97
start_service() {
 procd_open_instance
 procd_set_param command /usr/libexec/cpe5g-mwan3-gated-reconcile
 procd_set_param env CPE5G_RECONCILE_BIN=/usr/libexec/cpe5g-ipv6-reconcile
 procd_set_param stdout 1
 procd_set_param stderr 1
 procd_close_instance
}
EOF
cat > "$FILES/etc/init.d/cpe6-route-audit-bootstrap" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=96
start_service() {
 procd_open_instance
 procd_set_param command /usr/bin/node /usr/libexec/cpe5g-ipv6/audit-bootstrap.mjs
 procd_set_param stdout 1
 procd_set_param stderr 1
 procd_set_param term_timeout 5
 procd_set_param respawn 3600 5 0
 procd_close_instance
}
EOF
cat > "$FILES/etc/uci-defaults/93-cpe-5g-ipv6" <<'EOF'
#!/bin/sh
/etc/init.d/cpe6-route-audit-bootstrap enable
/etc/init.d/cpe6-route-audit-bootstrap start
/etc/init.d/cpe5g-ipv6-reconcile enable
/etc/init.d/cpe5g-ipv6-reconcile start
exit 0
EOF
chmod 755 "$FILES/etc/init.d/cpe6-route-audit-bootstrap" "$FILES/lib/netifd/proto/cpe6.sh" "$FILES/usr/libexec/cpe5g-ipv6-reconcile" "$FILES/usr/sbin/cpe5g-ipv6" "$FILES/etc/init.d/cpe5g-ipv6-reconcile" "$FILES/etc/uci-defaults/93-cpe-5g-ipv6"
echo 'CPE IPv6: guarded native prefix sharing staged for netifd'
