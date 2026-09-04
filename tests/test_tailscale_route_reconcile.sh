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
sh -n "$SCRIPT"
sh -n "$INIT"
sh -n "$DEFAULTS"

grep -q "PrimaryRoutes" "$SCRIPT" || { echo "helper does not derive routes from netmap"; exit 1; }
grep -q "jsonfilter" "$SCRIPT" || { echo "helper does not use the OpenWrt JSON parser"; exit 1; }
grep -q "table 52" "$SCRIPT" || { echo "helper does not inspect table 52"; exit 1; }
grep -q "force-netmap-update" "$SCRIPT" || { echo "helper lacks the non-disruptive refresh step"; exit 1; }
grep -q "RESTART_COOLDOWN" "$SCRIPT" || { echo "helper lacks restart cooldown"; exit 1; }
if grep -Eq '192\.168\.(8|9|10|11|12|101)' "$SCRIPT"; then
	echo "helper hardcodes a production subnet"
	exit 1
fi

grep -q "config route_reconcile 'route_reconcile'" "$CONFIG" || {
	echo "tailscale config does not expose route reconcile settings"
	exit 1
}
grep -q "config route_reconcile 'route_reconcile'" "$FALLBACK" || {
	echo "tailscale fallback does not expose route reconcile settings"
	exit 1
}
grep -q "/etc/init.d/tailscale-route-reconcile enable" "$DEFAULTS" || {
	echo "route reconcile defaults do not enable the service"
	exit 1
}

# Runtime fixture: use an arbitrary subnet to prove that the helper follows
# netmap data, waits for two confirmations, then restarts once. A later healthy
# check clears the failure counter without another restart.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$BIN_DIR"

cat >"$BIN_DIR/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$BIN_DIR/tailscale" <<'EOF'
#!/bin/sh
case "$1:$2" in
	status:--json)
		printf '%s\n' '{"BackendState":"Running"}'
		;;
	debug:netmap)
		printf '%s\n' '{"Peers":[{"Online":true,"PrimaryRoutes":["10.42.0.0/16"]}]}'
		;;
	debug:force-netmap-update)
		if [ -f "$FIXTURE_ROOT/refresh-restores" ]; then
			touch "$FIXTURE_ROOT/routes-ok"
			exit 0
		fi
		exit 1
		;;
	*)
		exit 1
		;;
esac
EOF

cat >"$BIN_DIR/jsonfilter" <<'EOF'
#!/bin/sh
printf '%s\n' '10.42.0.0/16'
EOF

cat >"$BIN_DIR/ip" <<'EOF'
#!/bin/sh
if [ -f "$FIXTURE_ROOT/routes-ok" ]; then
	printf '%s\n' '10.42.0.0/16 dev tailscale0'
fi
EOF

cat >"$BIN_DIR/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FIXTURE_ROOT/log"
EOF

cat >"$BIN_DIR/date" <<'EOF'
#!/bin/sh
printf '%s\n' '1000'
EOF

cat >"$BIN_DIR/tailscale-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FIXTURE_ROOT/restarts"
EOF

chmod +x "$BIN_DIR"/*

export FIXTURE_ROOT="$WORK_DIR"
export TSRC_PATH="$BIN_DIR:/usr/sbin:/usr/bin:/sbin:/bin"
export TSRC_RUNTIME_DIR="$WORK_DIR/runtime"
export TSRC_TAILSCALE_INIT="$BIN_DIR/tailscale-init"
export TSRC_NETMAP_WAIT=0
export TSRC_FAILURE_THRESHOLD=2
export TSRC_RESTART_COOLDOWN=1800

"$SCRIPT" --check
[ ! -e "$WORK_DIR/restarts" ] || { echo "helper restarted before confirmation threshold"; exit 1; }
"$SCRIPT" --check
[ "$(wc -l <"$WORK_DIR/restarts")" -eq 1 ] || { echo "helper did not restart exactly once after confirmed loss"; exit 1; }
grep -q '^failures=0$' "$WORK_DIR/runtime/state" || { echo "restart did not clear failure counter"; exit 1; }

touch "$WORK_DIR/routes-ok"
"$SCRIPT" --check
[ "$(wc -l <"$WORK_DIR/restarts")" -eq 1 ] || { echo "healthy route check triggered another restart"; exit 1; }
grep -q '^last_action=0$' "$WORK_DIR/runtime/state" || { echo "healthy route check did not reset state"; exit 1; }

# A later incident is repaired by the no-op netmap refresh itself; a service
# restart is not needed when tailscaled repopulates table 52 in place.
rm -f "$WORK_DIR/routes-ok"
touch "$WORK_DIR/refresh-restores"
"$SCRIPT" --check
"$SCRIPT" --check
[ "$(wc -l <"$WORK_DIR/restarts")" -eq 1 ] || { echo "netmap refresh path caused an unnecessary restart"; exit 1; }
grep -q 'netmap refresh restored table 52 routes' "$WORK_DIR/log" || { echo "netmap refresh recovery was not logged"; exit 1; }

echo "tailscale route reconcile fixture passed"
