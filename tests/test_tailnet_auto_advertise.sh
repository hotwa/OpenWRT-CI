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
grep -Fq 'advertise_routes="${lan_ip%.*}.0/24"' "$ENROLL_BIN"

echo "tailnet auto-advertise guard tests passed"