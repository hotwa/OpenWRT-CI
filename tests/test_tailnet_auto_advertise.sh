#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENROLL_SCRIPT="$ROOT_DIR/Scripts/HeadscaleAutoEnroll.sh"
ENROLL_BIN="$ROOT_DIR/files/usr/sbin/headscale-auto-enroll"
DOC_FILE="$ROOT_DIR/docs/tailnet-mesh-multi-site.md"

[ -f "$ENROLL_SCRIPT" ] || { echo "missing HeadscaleAutoEnroll.sh"; exit 1; }
[ -f "$ENROLL_BIN" ] || { echo "missing headscale-auto-enroll binary"; exit 1; }
[ -f "$DOC_FILE" ] || { echo "missing tailnet-mesh-multi-site.md"; exit 1; }

grep -Fq 'HEADSCALE_OPENWRT_ACCEPT_ROUTES="${HEADSCALE_OPENWRT_ACCEPT_ROUTES:-1}"' "$ENROLL_SCRIPT"
grep -Fq 'derive_lan_subnet' "$ENROLL_SCRIPT"
grep -Fq 'accept_routes="$(cfg accept_routes 1)"' "$ENROLL_BIN"

HEADSCALE_AUTO_ENROLL_LIBRARY_ONLY=1 . "$ENROLL_BIN"

[ "$(derive_lan_route 192.168.11.1 24)" = "192.168.11.0/24" ] || {
	echo "runtime route derivation did not honor the LAN prefix"
	exit 1
}
validate_advertise_route "192.168.11.0/24" "192.168.11.1" "24" || {
	echo "runtime route validation rejected the active LAN prefix"
	exit 1
}

for invalid in \
	"0.0.0.0/0" \
	"8.8.8.0/24" \
	"192.168.0.0/16" \
	"192.168.11.1/24" \
	"192.168.12.0/24" \
	"192.168.11.0/24,192.168.12.0/24"; do
	if validate_advertise_route "$invalid" "192.168.11.1" "24"; then
		echo "runtime route validation accepted unsafe route: $invalid"
		exit 1
	fi
done

[ "$(netmask_to_prefix 255.255.255.128)" = "25" ] || {
	echo "netmask-to-prefix conversion failed"
	exit 1
}
if netmask_to_prefix 255.0.255.0 >/dev/null 2>&1; then
	echo "non-contiguous netmask was accepted"
	exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/etc/config" "$TMP_DIR/etc/tailscale"
cat >"$TMP_DIR/etc/config/headscale_auto_enroll" <<'EOF'
config enroll 'main'
	option enabled '0'
	option advertise_routes ''
EOF

if HEADSCALE_OPENWRT_AUTHKEY='hskey-auth-''test-only' \
	WRT_IP='192.168.11.1' \
	HEADSCALE_OPENWRT_ADVERTISE_ROUTES='10.0.0.0/8' \
	"$ENROLL_SCRIPT" "$TMP_DIR" >/dev/null 2>&1; then
	echo "build helper accepted an overbroad advertise route"
	exit 1
fi

HEADSCALE_OPENWRT_AUTHKEY='hskey-auth-''test-only' \
	WRT_IP='192.168.11.1' \
	HEADSCALE_OPENWRT_ADVERTISE_ROUTES='192.168.11.0/24' \
	"$ENROLL_SCRIPT" "$TMP_DIR" >/dev/null
grep -Fq "option advertise_routes '192.168.11.0/24'" "$TMP_DIR/etc/config/headscale_auto_enroll" || {
	echo "build helper did not persist the validated LAN route"
	exit 1
}

grep -Fq 'cleanup_auth_key_file "$auth_key_file" "$delete_auth_key_file"' "$ENROLL_BIN" || {
	echo "already-enrolled and recovered paths do not clean residual auth keys"
	exit 1
}
grep -Fq 'auth key remains recoverable from immutable /rom' "$ENROLL_BIN" || {
	echo "runtime does not warn about immutable SquashFS auth-key copies"
	exit 1
}

echo "tailnet auto-advertise guard tests passed"
