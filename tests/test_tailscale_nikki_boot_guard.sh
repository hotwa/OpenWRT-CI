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

grep -q '100.64.0.0/10' "$BOOT_GUARD" || {
	echo "boot guard does not preserve the Tailscale CGNAT range"
	exit 1
}

grep -q 'fd7a:115c:a1e0::/48' "$BOOT_GUARD" || {
	echo "boot guard does not preserve the Tailscale ULA range"
	exit 1
}

echo "tailscale Nikki boot guard test passed"
