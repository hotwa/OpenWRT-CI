#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/tailscale-quad100-health"
UCI_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/99-tailscale-quad100-health"

[ -f "$INIT_SCRIPT" ] || { echo "missing tailscale Quad100 health init script"; exit 1; }
[ -f "$UCI_DEFAULTS" ] || { echo "missing tailscale Quad100 health uci-defaults"; exit 1; }

grep -q '100.100.100.100' "$INIT_SCRIPT" || {
  echo "Quad100 health script does not probe 100.100.100.100"
  exit 1
}

grep -q '53' "$INIT_SCRIPT" || {
	echo "Quad100 health script does not probe DNS port 53"
	exit 1
}

grep -q "jsonfilter -e '@.Self.DNSName'" "$INIT_SCRIPT" || {
	echo "Quad100 health script must derive the current MagicDNS name dynamically"
	exit 1
}

grep -q 'nslookup "\$probe_name" "\$PROBE_HOST"' "$INIT_SCRIPT" || {
	echo "Quad100 health script must query the current MagicDNS name over UDP DNS"
	exit 1
}

grep -q "grep -q 'Name:'" "$INIT_SCRIPT" || {
	echo "Quad100 health script must match the DNS answer Name field"
	exit 1
}

grep -q 'nc -uz -w 2' "$INIT_SCRIPT" || {
	echo "Quad100 health script must use UDP for the nc fallback"
	exit 1
}

if grep -Eq 'nc -z -w|nslookup openwrt\.org' "$INIT_SCRIPT"; then
	echo "Quad100 health script must not probe TCP 53 or a public DNS name"
	exit 1
fi

grep -q 'while \[ "\$attempt" -lt 5 \]' "$INIT_SCRIPT" || {
  echo "Quad100 health script does not retry the probe five times"
  exit 1
}

grep -q 'logger -t tailscale-quad100-health' "$INIT_SCRIPT" || {
  echo "Quad100 health script does not log probe results"
  exit 1
}

grep -q '/etc/init.d/tailscale-quad100-health enable' "$UCI_DEFAULTS" || {
  echo "uci-defaults does not enable tailscale Quad100 health guard"
  exit 1
}

echo "tailscale Quad100 health test passed"
