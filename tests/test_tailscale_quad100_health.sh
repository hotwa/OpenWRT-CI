#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/tailscale-quad100-health"
PROBE="$ROOT_DIR/files/usr/sbin/tailscale-quad100-health-probe"
MONITOR="$ROOT_DIR/files/usr/sbin/tailscale-quad100-health-monitor"
UCI_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/99-tailscale-quad100-health"

for path in "$INIT_SCRIPT" "$PROBE" "$MONITOR" "$UCI_DEFAULTS"; do
  [ -f "$path" ] || { echo "missing Quad100 health component: $path" >&2; exit 1; }
done
for path in "$PROBE" "$MONITOR" "$UCI_DEFAULTS"; do [ -x "$path" ] || exit 1; done
sh -n "$INIT_SCRIPT"
sh -n "$PROBE"
sh -n "$MONITOR"
grep -Fq '100.100.100.100' "$PROBE"
grep -Fq 'unknown tailscale-not-ready' "$PROBE"
grep -Fq 'timestamp_epoch=' "$PROBE"
grep -Fq 'fqdn=' "$PROBE"
grep -Fq 'address=' "$PROBE"
grep -Fq 'procd_set_param respawn 3600 5 0' "$INIT_SCRIPT"
if grep -Fq 'procd_set_param respawn 0 0 0' "$INIT_SCRIPT"; then
  echo "Quad100 one-shot work must not be configured as an immediate respawn loop" >&2
  exit 1
fi
grep -Fq '/etc/init.d/tailscale-quad100-health enable' "$UCI_DEFAULTS"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' '{"BackendState":"Running","Self":{"DNSName":"cs07-10.hs.jmsu.top."}}'
EOF
cat >"$BIN_DIR/jq" <<'EOF'
#!/bin/sh
case "$*" in *DNSName*) printf '%s\n' 'cs07-10.hs.jmsu.top.' ;; esac
EOF
cat >"$BIN_DIR/pgrep" <<'EOF'
#!/bin/sh
[ "${TAILSCALED_RUNNING:-1}" = 1 ]
EOF
cat >"$BIN_DIR/ip" <<'EOF'
#!/bin/sh
[ "${TAILSCALE_LINK_UP:-1}" = 1 ]
EOF
cat >"$BIN_DIR/nslookup" <<'EOF'
#!/bin/sh
printf '%s\t%s\n' "$1" "$2" >>"${NSLOOKUP_CALLS:?}"
case "${DNS_MODE:-good}" in
  good) printf 'Server: 100.100.100.100\nAddress 1: 100.100.100.100\nName: %s\nAddress 1: 100.64.0.37\n' "$1" ;;
  mismatch) printf 'Name: another.hs.jmsu.top\nAddress 1: 100.64.0.37\n' ;;
  no-address) printf 'Name: %s\n' "$1" ;;
  servfail) printf 'Server: 100.100.100.100\nAddress 1: 100.100.100.100\n** server cannot find %s: SERVFAIL\n' "$1"; exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$BIN_DIR/logger"
chmod 0755 "$BIN_DIR"/*
STATE="$WORK_DIR/state"
export NSLOOKUP_CALLS="$WORK_DIR/nslookup.calls"

run_probe() {
  env PATH="$BIN_DIR:$PATH" QUAD100_STATE_FILE="$STATE" "$@" "$PROBE"
}

TAILSCALED_RUNNING=0 run_probe
grep -Fqx 'state=unknown' "$STATE"
grep -Fqx 'reason=tailscale-not-ready' "$STATE"

run_probe
grep -Fqx 'state=ok' "$STATE" || { cat "$STATE" >&2; cat "$NSLOOKUP_CALLS" >&2; exit 1; }
grep -Fqx 'fqdn=cs07-10.hs.jmsu.top' "$STATE"
grep -Fqx 'address=100.64.0.37' "$STATE"
grep -Eq '^timestamp_epoch=[0-9]+$' "$STATE"

DNS_MODE=mismatch run_probe
grep -Fqx 'state=failed' "$STATE"
grep -Fqx 'reason=no-matching-address' "$STATE"

DNS_MODE=no-address run_probe
grep -Fqx 'state=failed' "$STATE"

DNS_MODE=servfail run_probe
grep -Fqx 'state=failed' "$STATE"

QUAD100_NSLOOKUP_BIN="$WORK_DIR/missing-nslookup" run_probe
grep -Fqx 'state=failed' "$STATE"
grep -Fqx 'reason=resolver-unavailable' "$STATE"

echo "tailscale Quad100 health checks passed"
