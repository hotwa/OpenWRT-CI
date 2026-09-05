#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "firmware default hardening: $*" >&2; exit 1; }

# --- 1. odhcpd LAN IPv6 configuration: PPPoE WAN deployments have no public
# IPv6 prefix today, so the upstream default ra=server spams "no public prefix
# on lan" in the log.  ra=hybrid resolves this at the source: it falls back to
# silent relay mode without a prefix and automatically becomes a full RA/SLAAC
# server once prefix delegation is available.  DHCPv6 stays server-capable.
ODHCPD="$ROOT_DIR/files/etc/uci-defaults/95-odhcpd-lan-config"
[ -f "$ODHCPD" ] || fail "missing $ODHCPD"
[ ! -f "$ROOT_DIR/files/etc/uci-defaults/95-odhcpd-ra-optout" ] || fail "old ra-optout patch still present"
bash -n "$ODHCPD" || fail "$ODHCPD does not parse"
grep -Fq "ra='hybrid'" "$ODHCPD" || fail "odhcpd script does not set ra=hybrid"
grep -Fq "dhcpv6='server'" "$ODHCPD" || fail "odhcpd script does not keep dhcpv6=server"
grep -Fq "ra_slaac='1'" "$ODHCPD" || fail "odhcpd script does not keep ra_slaac=1"
grep -Fq '/etc/config/dhcp' "$ODHCPD" || fail "odhcpd script does not guard the dhcp config"
grep -Fq 'uci -q commit dhcp' "$ODHCPD" || fail "odhcpd script does not commit dhcp"
if grep -Eq "ra_disabled=" "$ODHCPD"; then
	fail "odhcpd script still uses the temporary ra_disabled workaround"
fi

# --- 2. nikki/mihomo external controller binds the LAN address instead of
# the package default [::] (WAN-exposed management API).
NIKKI="$ROOT_DIR/files/etc/uci-defaults/96-nikki-bind-lan"
[ -f "$NIKKI" ] || fail "missing $NIKKI"
bash -n "$NIKKI" || fail "$NIKKI does not parse"
grep -Fq 'network.lan.ipaddr' "$NIKKI" || fail "nikki script does not resolve the LAN address"
grep -Fq 'api_listen' "$NIKKI" || fail "nikki script does not set api_listen"
grep -Fq 'nikki.mixin.api_listen' "$NIKKI" || fail "nikki script targets the wrong config path"
grep -Fq 'uci -q commit nikki' "$NIKKI" || fail "nikki script does not commit nikki"
if grep -Eq '127\.0\.0\.1:9090|\[::\]:9090' "$NIKKI"; then
	fail "nikki script hardcodes an address instead of deriving the LAN IP"
fi

# --- 3. Agent-Runtime-Bump musl probe must not nest single quotes inside the
# outer sh -ec '...' literal: the shell strips them and node receives an
# unquoted require() argument (SyntaxError). The fix uses \" escapes.
BUMP="$ROOT_DIR/.github/workflows/Agent-Runtime-Bump.yml"
[ -f "$BUMP" ] || fail "missing $BUMP"
grep -Fq 'require(\"@napi-rs/keyring\")' "$BUMP" || fail "musl probe still nests single quotes around @napi-rs/keyring"
grep -Fq 'require(\"zigpty\")' "$BUMP" || fail "musl probe still nests single quotes around zigpty"
if grep -Fq "require('@napi-rs/keyring')" "$BUMP"; then
	fail "musl probe reintroduced single-quote nesting"
fi

echo "firmware default hardening tests passed"
