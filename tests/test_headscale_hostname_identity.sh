#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/headscale-auto-enroll"
MIGRATION="$ROOT_DIR/files/etc/uci-defaults/99-headscale-identity-migration"

[ -x "$SCRIPT" ] || { echo "missing executable Headscale enrollment script" >&2; exit 1; }
[ -x "$MIGRATION" ] || { echo "missing executable Headscale identity migration" >&2; exit 1; }

HEADSCALE_AUTO_ENROLL_LIBRARY_ONLY=1
# shellcheck source=/dev/null
. "$SCRIPT"

[ "$(build_hostname lan-site '' '' re-cs-02 192.168.11.1)" = 'cs02-11' ] || {
	echo "RE-CS-02 LAN identity is not cs02-11" >&2
	exit 1
}

[ "$(build_hostname lan-site '' '' re-ss-01 192.168.13.1)" = 'ss01-13' ] || {
	echo "model must not be inferred from the LAN third octet" >&2
	exit 1
}

[ "$(build_hostname explicit 'Emergency Router' '' '' 192.168.11.1)" = 'emergency-router' ] || {
	echo "explicit break-glass hostname was not sanitized" >&2
	exit 1
}

if build_hostname lan-site '' '' re-cs-07 203.0.113.1 >/dev/null 2>&1; then
	echo "public address must not produce a LAN-derived hostname" >&2
	exit 1
fi

if build_hostname unsupported '' '' re-cs-07 192.168.10.1 >/dev/null 2>&1; then
	echo "unknown hostname mode must fail closed" >&2
	exit 1
fi

echo "headscale hostname identity test passed"
