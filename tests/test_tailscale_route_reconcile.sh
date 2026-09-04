#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/tailscale-route-reconcile"
INIT="$ROOT_DIR/files/etc/init.d/tailscale-route-reconcile"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/99-tailscale-route-reconcile"
CONFIG="$ROOT_DIR/files/etc/config/tailscale"
FALLBACK="$ROOT_DIR/files/etc/uci-defaults/96-tailscale-uci-fallback"

[ -x "$SCRIPT" ] || { echo "route reconcile helper is not executable"; exit 1; }
[ -x "$INIT" ] || { echo "route reconcile init script is not executable"; exit 1; }
[ -x "$DEFAULTS" ] || { echo "route reconcile defaults script is not executable"; exit 1; }
sh -n "$SCRIPT" "$INIT" "$DEFAULTS"

grep -q 'debug netmap' "$SCRIPT"
grep -q 'BackendState' "$SCRIPT"
grep -q 'Self' "$SCRIPT"
grep -q 'PrimaryRoutes' "$SCRIPT"
grep -q '100.100.100.100' "$SCRIPT"
grep -q 'route show table all' "$SCRIPT"
grep -q 'from all lookup' "$SCRIPT"
grep -q 'ping -c 1 -W 2' "$SCRIPT"
grep -q 'headscale-auto-enroll.lock' "$SCRIPT"
grep -q 'force-netmap-update' "$SCRIPT"
grep -q 'FAIL_ADDR' "$SCRIPT"
grep -q 'FAIL_OTHER' "$SCRIPT"
grep -q 'UPGRADED' "$SCRIPT"
grep -q 'LAST_RESTART' "$SCRIPT"
grep -q -- '--once' "$SCRIPT"
grep -q -- '--check' "$SCRIPT"
grep -q -- '--status' "$SCRIPT"
grep -q -- '--loop' "$SCRIPT"
if grep -Eq 'Online[ =]' "$SCRIPT"; then
  echo "helper must not use the unreliable netmap/status Online flag"
  exit 1
fi
if grep -Eq 'route (add|replace|del)' "$SCRIPT"; then
  echo "helper must remain read-only and never mutate kernel routes"
  exit 1
fi
grep -q "config route_reconcile 'route_reconcile'" "$CONFIG"
grep -q "config route_reconcile 'route_reconcile'" "$FALLBACK"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$BIN_DIR"

cat >"$BIN_DIR/tailscale" <<'EOF'
#!/bin/sh
case "$1:$2" in
  status:--json)
    printf '%s
' '{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.2/32"]}}'
    ;;
  debug:netmap)
    if [ "${EMPTY_NETMAP:-0}" = 1 ]; then
      echo '{"Peers":[]}'
      exit 0
    fi
    printf '%s
' '{"Peers":[{"Online":false,"Addresses":["100.64.0.3/32"],"PrimaryRoutes":["10.42.0.0/16"]}]}'
    ;;
  debug:force-netmap-update)
    printf '%s
' force >>"$FIXTURE_ROOT/actions"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$BIN_DIR/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "-4 link show dev tailscale0")
    exit 0
    ;;
  "-4 addr show dev tailscale0")
    if [ -f "$FIXTURE_ROOT/addr-ok" ]; then
      printf '%s
' '    inet 100.64.0.2/32 scope global tailscale0'
    fi
    ;;
  "-4 rule show")
    printf '%s
' '100: from all lookup 1234'
    ;;
  "-4 route show table all"|"-4 route show table 1234")
    if [ -f "$FIXTURE_ROOT/routes-ok" ]; then
      printf '%s
'         '100.64.0.3 dev tailscale0 table 1234'         '10.42.0.0/16 dev tailscale0 table 1234'         '100.100.100.100 dev tailscale0 table 1234'
    fi
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$BIN_DIR/ping" <<'EOF'
#!/bin/sh
[ -f "$FIXTURE_ROOT/routes-ok" ]
EOF

cat >"$BIN_DIR/logger" <<'EOF'
#!/bin/sh
printf '%s
' "$*" >>"$FIXTURE_ROOT/log"
EOF

cat >"$BIN_DIR/date" <<'EOF'
#!/bin/sh
printf '%s
' 1000
EOF

cat >"$BIN_DIR/tailscale-init" <<'EOF'
#!/bin/sh
printf '%s
' restart >>"$FIXTURE_ROOT/actions"
touch "$FIXTURE_ROOT/routes-ok" "$FIXTURE_ROOT/addr-ok"
EOF

chmod +x "$BIN_DIR"/*
count_action() {
  [ -f "$WORK_DIR/actions" ] || { printf '0\n'; return 0; }
  grep -c "^$1$" "$WORK_DIR/actions" || true
}
export FIXTURE_ROOT="$WORK_DIR"
export TSRC_PATH="$BIN_DIR:/usr/local/bin:/usr/bin:/bin"
export TSRC_STATE_FILE="$WORK_DIR/tailscale-route-reconcile.state"
export TSRC_RUNTIME_DIR="$WORK_DIR/runtime"
export TSRC_LOCK_DIR="$WORK_DIR/route-lock"
export TSRC_TAILSCALE_INIT="$BIN_DIR/tailscale-init"
export TSRC_NETMAP_WAIT=0
export TSRC_FAILURE_THRESHOLD=2
export TSRC_RESTART_COOLDOWN=1800
export TSRC_CHECK_INTERVAL=1
touch "$WORK_DIR/routes-ok" "$WORK_DIR/addr-ok"

"$SCRIPT" --status | grep -q '^health=healthy$'
"$SCRIPT" --once
[ ! -e "$WORK_DIR/actions" ] || { echo "healthy baseline triggered repair"; exit 1; }

rm -f "$WORK_DIR/routes-ok"
"$SCRIPT" --once
[ ! -e "$WORK_DIR/actions" ] || { echo "route drift repaired before confirmation"; exit 1; }
"$SCRIPT" --once
[ "$(count_action force)" -eq 1 ] || { echo "route drift did not trigger one force update"; exit 1; }
[ "$(count_action restart)" -eq 0 ] || { echo "route drift restarted too early"; exit 1; }
"$SCRIPT" --once
[ "$(count_action restart)" -eq 1 ] || { echo "route drift did not restart on third failure"; exit 1; }
grep -q 'post-repair verification PASSED' "$WORK_DIR/log"

export TSRC_RESTART_COOLDOWN=0
rm -f "$WORK_DIR/addr-ok" "$WORK_DIR/routes-ok" "$WORK_DIR/actions"
"$SCRIPT" --once
[ ! -e "$WORK_DIR/actions" ] || { echo "address drift repaired before confirmation"; exit 1; }
"$SCRIPT" --once
[ "$(count_action restart)" -eq 1 ] || { echo "address drift did not restart directly"; exit 1; }
[ "$(count_action force)" -eq 0 ] || { echo "address drift incorrectly forced netmap update"; exit 1; }

export TSRC_RESTART_COOLDOWN=1800
rm -f "$WORK_DIR/routes-ok" "$WORK_DIR/addr-ok" "$WORK_DIR/actions"
"$SCRIPT" --once
"$SCRIPT" --once
"$SCRIPT" --once
[ "$(count_action restart)" -eq 0 ] || { echo "restart cooldown was bypassed"; exit 1; }
grep -q 'cooldown' "$WORK_DIR/log"

export EMPTY_NETMAP=1
rm -f "$WORK_DIR/actions"
"$SCRIPT" --once
[ ! -e "$WORK_DIR/actions" ] || { echo "empty netmap was treated as a repairable failure"; exit 1; }
unset EMPTY_NETMAP

mkdir -p "$WORK_DIR/enroll-lock"
sleep 30 &
ENROLL_PID=$!
printf '%s
' "$ENROLL_PID" >"$WORK_DIR/enroll-lock/pid"
export HEADSCALE_AUTO_ENROLL_LOCK_DIR="$WORK_DIR/enroll-lock"
rm -f "$WORK_DIR/actions"
"$SCRIPT" --once
kill "$ENROLL_PID" 2>/dev/null || true
[ ! -e "$WORK_DIR/actions" ] || { echo "active auto-enroll lock was ignored"; exit 1; }

echo "tailscale route reconcile test passed"
