#!/bin/sh
[ -n "${INCLUDE_ONLY:-}" ] || {
 . /lib/functions.sh
 if [ -r /lib/netifd/netifd-proto.sh ]; then . /lib/netifd/netifd-proto.sh; else . /lib/netifd/proto.sh; fi
 init_proto "$@"
}
proto_cpe6_init_config() {
 proto_config_add_string 'host' 'lan' 'mode'
 proto_config_add_int 'port' 'interval' 'lifetime'
 available=1
 no_device=0
}
proto_cpe6_setup() {
 local interface="$1" device="$2" host port lan mode interval lifetime
 json_get_vars host port lan mode interval lifetime
 proto_run_command "$interface" /usr/sbin/cpe5g-ipv6 "$interface" "$device" "${host:-192.168.66.1}" "${port:-5555}" "${lan:-lan}" "${mode:-lan}" "${interval:-15}" "${lifetime:-180}"
}
proto_cpe6_teardown() { proto_kill_command "$1"; }
[ -n "${INCLUDE_ONLY:-}" ] || add_protocol cpe6
