#!/bin/sh
set -eu
cfg() { uci -q get "cpe5g_ipv6.main.$1" 2>/dev/null || printf '%s' "$2"; }
put() {
 local key="$1" wanted="$2" actual
 actual="$(uci -q get "$key" 2>/dev/null || true)"
 [ "$actual" = "$wanted" ] && return 0
 uci set "$key=$wanted"; changed=1
}
changed=0
enabled="$(cfg enabled 1)"
if [ "$enabled" != 1 ]; then
 if [ "$(uci -q get network.cpe6 2>/dev/null || true)" = interface ]; then
  put network.cpe6.auto 0
  [ "$changed" = 0 ] || uci commit network
  ifdown cpe6 >/dev/null 2>&1 || true
 fi
 exit 0
fi
[ "$(uci -q get network.5G 2>/dev/null || true)" = interface ] || exit 1
lan="$(cfg lan lan)"
case "$lan" in ''|*[!A-Za-z0-9_-]*) exit 1;; esac
[ "$(uci -q get "network.$lan" 2>/dev/null || true)" = interface ] || exit 1
put network.cpe6 interface
put network.cpe6.proto cpe6
put network.cpe6.device "$(cfg device usb0)"
put network.cpe6.host "$(cfg host 192.168.66.1)"
put network.cpe6.port "$(cfg port 5555)"
put network.cpe6.lan "$lan"
put network.cpe6.mode "$(cfg mode lan)"
put network.cpe6.interval "$(cfg interval 15)"
put network.cpe6.lifetime "$(cfg lifetime 180)"
put network.cpe6.auto 1
put network.cpe6.delegate 1
put "network.$lan.ip6assign" 64
# Allow the local ULA and this one native upstream; never Ethernet WAN PD.
if ! uci -q show "network.$lan.ip6class" 2>/dev/null | grep -q "='local' 'cpe6'$"; then
 uci -q delete "network.$lan.ip6class" || true
 uci add_list "network.$lan.ip6class=local"
 uci add_list "network.$lan.ip6class=cpe6"
 changed=1
fi
put "dhcp.$lan.ra" server
put "dhcp.$lan.dhcpv6" server
put "dhcp.$lan.ra_slaac" 1
# Dual-stack LAN clients keep the existing IPv4 DHCP DNS pipeline; do not
# cache the short-lived cellular GUA as their recursive DNS server.
put "dhcp.$lan.ra_dns" 0
put "dhcp.$lan.ra_default" 0
# Worker opens public PIOs only after prefix, quota and routing are ready.
put "dhcp.$lan.prefix_filter" 'fc00::/7'
put "dhcp.$lan.ra_mininterval" 30
put "dhcp.$lan.ra_maxinterval" 60
put "dhcp.$lan.ndp" disabled
zone=''
for z in $(uci show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
 [ "$(uci -q get "firewall.$z.name" 2>/dev/null || true)" != wan ] || zone="$z"
done
[ -n "$zone" ] || exit 1
case " $(uci -q get "firewall.$zone.network" || true) " in
 *' cpe6 '*) ;;
 *) uci add_list "firewall.$zone.network=cpe6"; changed=1;;
esac
if [ "$changed" = 1 ]; then
 uci commit network; uci commit dhcp; uci commit firewall
 ubus call network reload >/dev/null
 /etc/init.d/odhcpd reload
 /etc/init.d/firewall reload
fi
