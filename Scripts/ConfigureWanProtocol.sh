#!/usr/bin/env bash
# Inject WAN credentials only into a private firmware overlay.  GitHub Actions
# workflow_dispatch has no secret input type, so this intentionally consumes
# repository secrets rather than accepting a plaintext password as an input.
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
PROTOCOL="${WRT_WAN_PROTOCOL:-dhcp}"
USERNAME="${OPENWRT_WAN_PPPOE_USERNAME:-}"
PASSWORD="${OPENWRT_WAN_PPPOE_PASSWORD:-}"
DEFAULTS="$TARGET_FILES/etc/uci-defaults/97-wan-pppoe"

case "$PROTOCOL" in
  dhcp) exit 0 ;;
  pppoe) ;;
  *) echo 'WRT_WAN_PROTOCOL must be dhcp or pppoe' >&2; exit 1 ;;
esac

[ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || {
  echo 'PPPoE requires OPENWRT_WAN_PPPOE_USERNAME and OPENWRT_WAN_PPPOE_PASSWORD secrets' >&2
  exit 1
}
case "$USERNAME$PASSWORD" in
  *$'\n'*|*$'\r'*) echo 'PPPoE credentials must not contain a newline' >&2; exit 1 ;;
esac

USERNAME_B64="$(printf '%s' "$USERNAME" | base64 | tr -d '\n')"
PASSWORD_B64="$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')"
mkdir -p "$(dirname "$DEFAULTS")"
umask 077
cat >"$DEFAULTS" <<EOF
#!/bin/sh
set -eu

username="\$(printf '%s' '$USERNAME_B64' | base64 -d)"
password="\$(printf '%s' '$PASSWORD_B64' | base64 -d)"
[ -n "\$username" ] && [ -n "\$password" ] || exit 1
uci set 'network.wan=interface'
uci set 'network.wan.proto=pppoe'
uci set "network.wan.username=\$username"
uci set "network.wan.password=\$password"
uci commit network
exit 0
EOF
chmod 700 "$DEFAULTS"
printf '%s\n' 'PPPoE configuration injected from private repository secrets'
