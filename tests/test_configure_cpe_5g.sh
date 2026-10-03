#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/ConfigureCpe5G.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ -x "$SCRIPT" ] || {
  echo "missing executable ConfigureCpe5G.sh"
  exit 1
}

mkdir -p "$TMP_DIR/disabled" "$TMP_DIR/enabled"
"$SCRIPT" "$TMP_DIR/disabled" false
[ ! -e "$TMP_DIR/disabled/etc/uci-defaults/92-cpe-5g-network" ] || {
  echo "disabled CPE network bootstrap must not create an overlay"
  exit 1
}

"$SCRIPT" "$TMP_DIR/enabled" true
BOOTSTRAP="$TMP_DIR/enabled/etc/uci-defaults/92-cpe-5g-network"
[ -x "$BOOTSTRAP" ] || {
  echo "enabled CPE network bootstrap is missing or not executable"
  exit 1
}

grep -q "uci set network.5G='interface'" "$BOOTSTRAP"
grep -q "uci set network.5G.device='usb0'" "$BOOTSTRAP"
grep -q "uci set network.5G.proto='dhcp'" "$BOOTSTRAP"
grep -q "uci set network.wan.ipv6='0'" "$BOOTSTRAP"
grep -q "uci set network.5G.ipv6='0'" "$BOOTSTRAP"
grep -q "uci set network.wan6.auto='0'" "$BOOTSTRAP"
if grep -q '^/usr/libexec/cpe5g-mwan3-reconcile$' "$BOOTSTRAP"; then
  echo "bootstrap must not race the gate-aware reconcile service"
  exit 1
fi
grep -q '^/etc/init.d/cpe5g-mwan3-reconcile start$' "$BOOTSTRAP" || {
  echo "bootstrap must start the gate-aware reconcile service on first boot"
  exit 1
}
grep -q "uci add_list firewall.\$wan_zone.network='5G'" "$BOOTSTRAP"
grep -q "uci add firewall forwarding" "$BOOTSTRAP"
grep -q "uci set firewall.\$forwarding.src='lan'" "$BOOTSTRAP"
grep -q "uci set firewall.\$forwarding.dest='wan'" "$BOOTSTRAP"
sh -n "$BOOTSTRAP"

RECONCILE="$TMP_DIR/enabled/usr/libexec/cpe5g-mwan3-reconcile"
GATED="$TMP_DIR/enabled/usr/libexec/cpe5g-mwan3-gated-reconcile"
INIT="$TMP_DIR/enabled/etc/init.d/cpe5g-mwan3-reconcile"
[ -x "$RECONCILE" ] && [ -x "$GATED" ] && [ -x "$INIT" ] || {
  echo "CPE-5G managed mwan3 reconcile files are missing"
  exit 1
}

grep -q 'set_network_option network.wan.metric 10' "$RECONCILE"
grep -q 'set_network_option network.wan.ipv6 0' "$RECONCILE"
grep -q 'set_network_option network.5G.ipv6 0' "$RECONCILE"
grep -q 'set_network_option network.wan6.auto 0' "$RECONCILE"
grep -q 'set_network_option network.wan6.disabled 1' "$RECONCILE"
grep -q 'set_network_option network.5G.metric 20' "$RECONCILE"
grep -q 'set_network_option network.5G.defaultroute 1' "$RECONCILE"
grep -q 'set_network_option network.5G.peerdns 0' "$RECONCILE"
grep -q "uci set mwan3.wan='interface'" "$RECONCILE"
grep -q "uci set mwan3.5G='interface'" "$RECONCILE"
grep -q "mwan3.wan.reliability='2'" "$RECONCILE"
grep -q "mwan3.wan.interval='5'" "$RECONCILE"
grep -q "mwan3.5G.interval='60'" "$RECONCILE"
grep -q "mwan3.wan.down='3'" "$RECONCILE"
grep -q "mwan3.wan.up='5'" "$RECONCILE"
grep -q "223.5.5.5" "$RECONCILE"
grep -q "119.29.29.29" "$RECONCILE"
grep -q "1.1.1.1" "$RECONCILE"
grep -q 'reset_managed_section cpe5g_failover policy' "$RECONCILE"
grep -q "mwan3.cpe5g_failover.last_resort='unreachable'" "$RECONCILE"
grep -q 'stock_rule_equals https rule' "$RECONCILE"
grep -q 'stock_rule_equals default_rule_v4 rule' "$RECONCILE"
grep -q 'stock_rule_equals default_rule_v6 rule dest_ip ::/0 use_policy balanced family ipv6' "$RECONCILE"
grep -q "mwan3.cpe5g_v6.use_policy='default'" "$RECONCILE"
grep -q "mwan3.cpe5g_tailnet.dest_ip='100.64.0.0/10'" "$RECONCILE"
grep -q "mwan3.cpe5g_private.dest_ip='192.168.0.0/16'" "$RECONCILE"
grep -q "uci add_list mwan3.globals.rt_table_lookup='52'" "$RECONCILE"
grep -q "mwan3.cpe5g_cpe.dest_ip='192.168.66.0/24'" "$RECONCILE"
grep -q 'mwan3.cpe5g_lan.dest_ip=\$lan_cidr' "$RECONCILE"
grep -q 'uci reorder mwan3.cpe5g_lan=0' "$RECONCILE"
grep -q 'uci reorder mwan3.cpe5g_cpe=0' "$RECONCILE"
grep -q 'call network reload' "$RECONCILE"
if grep -Eq 'reset_managed_section [^ ]{16,} (rule|policy)' "$RECONCILE"; then
  echo "mwan3 rule/policy names must not exceed 15 characters"
  exit 1
fi
grep -q "mwan3.cpe5g_default.use_policy='cpe5g_failover'" "$RECONCILE"
grep -Eq 'already_done\|restored\|no_backup\|failed_final\|disabled' "$GATED"
sh -n "$RECONCILE"
sh -n "$GATED"
sh -n "$INIT"

# Execute the generated resolver helper: an empty 5G interface needs a usable
# fallback, while existing user lists and subsequent runs must remain untouched.
awk '/^ensure_backup_dns\(\) \{/ { copy=1 } copy { print } copy && /^}$/ { exit }' \
  "$RECONCILE" >"$TMP_DIR/backup-dns-helper"
[ -s "$TMP_DIR/backup-dns-helper" ]
. "$TMP_DIR/backup-dns-helper"
uci() {
  [ "${1:-}" != -q ] || shift
  local command="$1" argument="${2:-}"
  case "$command" in
    get)
      [ "$argument" = network.5G.dns ] && [ -n "$dns_fixture" ] || return 1
      printf '%s\n' "$dns_fixture"
      ;;
    delete)
      [ "$argument" = network.5G.dns ] || return 2
      dns_fixture=''
      dns_writes=$((dns_writes + 1))
      ;;
    add_list)
      case "$argument" in network.5G.dns=*) ;; *) return 2 ;; esac
      dns_fixture="${dns_fixture:+$dns_fixture }${argument#*=}"
      dns_writes=$((dns_writes + 1))
      ;;
    *) return 2 ;;
  esac
}
dns_fixture=''
dns_writes=0
network_changed=0
backup_dns_added=0
ensure_backup_dns
[ "$dns_fixture" = '223.5.5.5 119.29.29.29' ]
[ "$network_changed" -eq 1 ] && [ "$backup_dns_added" -eq 1 ]
first_dns_writes="$dns_writes"
network_changed=0
backup_dns_added=0
ensure_backup_dns
[ "$dns_writes" -eq "$first_dns_writes" ]
[ "$network_changed" -eq 0 ] && [ "$backup_dns_added" -eq 0 ]
dns_fixture='9.9.9.9 1.0.0.1'
dns_writes=0
ensure_backup_dns
[ "$dns_fixture" = '9.9.9.9 1.0.0.1' ] && [ "$dns_writes" -eq 0 ]
[ "$network_changed" -eq 0 ] && [ "$backup_dns_added" -eq 0 ]
dns_fixture=$' \t '
ensure_backup_dns
[ "$dns_fixture" = '223.5.5.5 119.29.29.29' ]
[ "$network_changed" -eq 1 ] && [ "$backup_dns_added" -eq 1 ]
unset -f uci ensure_backup_dns

if "$SCRIPT" "$TMP_DIR/enabled" invalid >/dev/null 2>&1; then
  echo "invalid CPE network bootstrap flag must fail"
  exit 1
fi

echo "CPE-5G network bootstrap test passed"
