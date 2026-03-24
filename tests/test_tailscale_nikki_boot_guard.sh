#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT_GUARD="$ROOT_DIR/files/etc/init.d/tailscale-nikki-guard"

[ -f "$BOOT_GUARD" ] || {
	echo "missing Nikki tailscale boot guard init script"
	exit 1
}

grep -q '/etc/config/nikki' "$BOOT_GUARD" || {
	echo "boot guard does not gate itself on Nikki being installed"
	exit 1
}

grep -q 'nikki.@router_access_control\[0\].enabled' "$BOOT_GUARD" || {
	echo "boot guard does not gate itself on the router access control section"
	exit 1
}

grep -q '100.64.0.0/10' "$BOOT_GUARD" || {
	echo "boot guard does not preserve the Tailscale CGNAT range"
	exit 1
}

grep -q 'fd7a:115c:a1e0::/48' "$BOOT_GUARD" || {
	echo "boot guard does not preserve the Tailscale ULA range"
	exit 1
}

grep -q 'services/mosdns' "$BOOT_GUARD" || {
	echo "boot guard does not preserve the mosdns router access bypass"
	exit 1
}

grep -q 'services/dnsmasq' "$BOOT_GUARD" || {
	echo "boot guard does not preserve the dnsmasq router access bypass"
	exit 1
}

grep -q 'services/tailscale' "$BOOT_GUARD" || {
	echo "boot guard does not preserve the tailscale router access bypass"
	exit 1
}

echo "tailscale Nikki boot guard test passed"
