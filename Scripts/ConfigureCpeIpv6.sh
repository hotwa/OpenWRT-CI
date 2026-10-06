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
mkdir -p "$FILES/usr/libexec/cpe5g-ipv6" "$FILES/usr/share/cpe5g-origin" "$FILES/lib/netifd/proto" "$FILES/lib/upgrade/keep.d" "$FILES/usr/sbin" "$FILES/etc/init.d" "$FILES/etc/uci-defaults" "$FILES/etc/config" "$FILES/etc/cpe5g" "$FILES/www/luci-static/resources/protocol"
for module in adb model probe worker audit-bootstrap quota-logger quota-ledger local-failover public-access select-origin-ipv6 lucky-origin deploy-origin-certificate restore-lucky-private reconcile-lucky-managed api-service-registry; do cp "$SOURCE/$module.mjs" "$FILES/usr/libexec/cpe5g-ipv6/$module.mjs"; done
for command in select-origin-ipv6 deploy-origin-certificate; do
 cp "$SOURCE/$command" "$FILES/usr/libexec/cpe5g-ipv6/$command"
 chmod 755 "$FILES/usr/libexec/cpe5g-ipv6/$command"
done
for command in cpe5g-lucky-persist cpe5g-lucky-start; do
 cp "$(dirname "$0")/$command" "$FILES/usr/libexec/$command"
 chmod 755 "$FILES/usr/libexec/$command"
done
# Override only the CPE B Lucky launcher; ordinary routers retain their package
# service. A procd worker waits for eMMC and restore before opening any listener.
cat > "$FILES/etc/init.d/lucky" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=15
start_service() {
 [ "$(uci -q get lucky.lucky.enabled 2>/dev/null || true)" = 1 ] || return 0
 procd_open_instance
 procd_set_param command /usr/libexec/cpe5g-lucky-start
 procd_set_param stdout 1
 procd_set_param stderr 1
 procd_set_param term_timeout 10
 procd_set_param respawn 3600 5 0
 procd_close_instance
}
service_triggers() { procd_add_reload_trigger lucky; }
EOF
chmod 755 "$FILES/etc/init.d/lucky"
# Public access stays closed in ordinary images; a private, encrypted build
# injects the validated per-device policy and native Lucky configuration.
printf '%s\n' '{"enabled":false}' > "$FILES/etc/cpe5g/public-origin.json"
chmod 600 "$FILES/etc/cpe5g/public-origin.json"
cat > "$FILES/lib/upgrade/keep.d/cpe5g-lucky" <<'EOF'
/etc/lucky/
/etc/cpe5g/public-origin.json
/etc/cpe5g-lucky/
/data/lucky/
/data/cpe5g-quota/
EOF
cp "$SOURCE/proto.sh" "$FILES/lib/netifd/proto/cpe6.sh"
cp "$SOURCE/reconcile.sh" "$FILES/usr/libexec/cpe5g-ipv6-reconcile"
cp "$SOURCE/origin-input-fence.nft" "$FILES/usr/share/cpe5g-origin/input-fence.nft"
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
cat > "$FILES/usr/libexec/cpe5g-lucky-origin-start" <<'EOF'
#!/bin/sh
set -eu
# Unlike managed route repair, public access never bypasses an unresolved
# firstboot restore decision. procd keeps this wait outside boot's hot path.
while :; do
 ready=1
 case "$(uci -q get wrtbak.main.firstboot_auto_enabled 2>/dev/null || true)" in
  1|true|yes|on|enabled)
   # A retained UCI file alone cannot run restore. Some CPE images omit
   # wrtbak; do not wait forever on their orphaned firstboot setting.
   if [ -x /etc/init.d/wrtbak-firstboot-auto ] && command -v wrtbak >/dev/null 2>&1; then
    state="$(jsonfilter -i /root/wrtbak/firstboot/gate.json -e '@.state' 2>/dev/null || true)"
    case "$state" in already_done|restored|no_backup|failed_final|disabled) ;; *) ready=0;; esac
   fi
   ;;
 esac
 awk '$2 == "/data" && $3 == "ext4" { ready=1 } END { exit !ready }' /proc/mounts || ready=0
 [ "$ready" = 0 ] || break
 sleep 5
done
# Bind before certificate restore or API reads. The same lock serializes the
# Lucky launcher and this worker; persistent data is authoritative on reboot.
/usr/libexec/cpe5g-lucky-persist
# Keep-config upgrades may restore older Lucky files over the private image.
# Restore only missing coherent material, then add only missing CPE entries.
# Either failure keeps the public listener closed until procd retries.
/usr/bin/node /usr/libexec/cpe5g-ipv6/restore-lucky-private.mjs
/usr/bin/node /usr/libexec/cpe5g-ipv6/reconcile-lucky-managed.mjs
# procd creates this wrapper's cgroup before exec. Wait for Lucky's group
# before refreshing Nikki's service-only bypass; this does not hold up boot.
if [ "$(uci -q get nikki.config 2>/dev/null || true)" = config ] && [ -e /sys/fs/cgroup/cgroup.controllers ]; then
 while [ ! -d /sys/fs/cgroup/services/lucky ] || [ ! -d /sys/fs/cgroup/services/cpe5g-lucky-origin ]; do sleep 5; done
 if [ -x /etc/init.d/nikki ] && /etc/init.d/nikki status >/dev/null 2>&1; then
  /etc/init.d/nikki reload
 fi
fi
exec /usr/bin/node /usr/libexec/cpe5g-ipv6/lucky-origin.mjs
EOF
cat > "$FILES/etc/init.d/cpe5g-lucky-origin" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=98
start_service() {
 procd_open_instance
 procd_set_param command /usr/libexec/cpe5g-lucky-origin-start
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
/etc/init.d/cpe5g-lucky-origin enable
/etc/init.d/cpe5g-lucky-origin start
exit 0
EOF
chmod 755 "$FILES/usr/libexec/cpe5g-lucky-origin-start" "$FILES/etc/init.d/cpe5g-lucky-origin" "$FILES/etc/init.d/cpe6-route-audit-bootstrap" "$FILES/lib/netifd/proto/cpe6.sh" "$FILES/usr/libexec/cpe5g-ipv6-reconcile" "$FILES/usr/sbin/cpe5g-ipv6" "$FILES/etc/init.d/cpe5g-ipv6-reconcile" "$FILES/etc/uci-defaults/93-cpe-5g-ipv6"
echo 'CPE IPv6: guarded native prefix sharing staged for netifd'
