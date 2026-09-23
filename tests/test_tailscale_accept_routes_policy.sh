#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/headscale-auto-enroll"
WORK_DIR="$(mktemp -d)"
BIN_DIR="$WORK_DIR/bin"
LOG_FILE="$WORK_DIR/calls.log"
LOCK_DIR="$WORK_DIR/enroll.lock"
GATE_FILE="$WORK_DIR/gate.json"

cleanup() {
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR"

cat >"$BIN_DIR/uci" <<'EOF'
#!/bin/sh
command=""
key=""
for arg in "$@"; do
	case "$arg" in
		get|set|commit) command="$arg" ;;
	esac
	key="$arg"
done

case "$command" in
	set|commit) exit 0 ;;
	get) ;;
	*) exit 1 ;;
esac

case "$key" in
	headscale_auto_enroll.main.enabled) printf '1\n' ;;
	headscale_auto_enroll.main.login_server) printf 'https://headscale.example.invalid\n' ;;
	headscale_auto_enroll.main.auth_key_file) printf '%s/authkey\n' "$TEST_ROOT" ;;
	headscale_auto_enroll.main.hostname_override) printf 'test-router\n' ;;
	headscale_auto_enroll.main.hostname_prefix) printf '\n' ;;
	headscale_auto_enroll.main.ssh) printf '1\n' ;;
	headscale_auto_enroll.main.accept_dns) printf '0\n' ;;
	headscale_auto_enroll.main.advertise_routes) printf '\n' ;;
	headscale_auto_enroll.main.max_attempts) printf '1\n' ;;
	headscale_auto_enroll.main.retry_interval) printf '0\n' ;;
	headscale_auto_enroll.main.restore_gate_file) printf '%s/gate.json\n' "$TEST_ROOT" ;;
	headscale_auto_enroll.main.restore_gate_attempts) printf '1\n' ;;
	headscale_auto_enroll.main.restore_gate_interval) printf '0\n' ;;
	headscale_auto_enroll.main.delete_auth_key_file) printf '0\n' ;;
	tailscale.settings.accept_routes) printf '%s\n' "${TEST_ACCEPT_ROUTES:-}" ;;
	wrtbak.main.firstboot_auto_enabled) printf '1\n' ;;
	network.lan.ipaddr) printf '192.168.12.1\n' ;;
	network.lan.netmask) printf '255.255.255.0\n' ;;
	*) exit 1 ;;
esac
EOF

cat >"$BIN_DIR/tailscale" <<'EOF'
#!/bin/sh
command="$1"
shift || true
case "$command" in
	status)
		if [ -f "$TEST_ROOT/state-running" ]; then
			printf '{"BackendState":"Running"}\n'
		else
			printf '{"BackendState":"Stopped"}\n'
		fi
		;;
	up|set) printf '%s %s\n' "$command" "$*" >>"$TEST_LOG" ;;
esac
EOF

cat >"$BIN_DIR/tailscale-init" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >>"$TEST_LOG"
if [ "${1:-}" = restart ]; then
	touch "$TEST_ROOT/state-running"
fi
EOF

for utility in ip logger sleep ubus; do
	cat >"$BIN_DIR/$utility" <<'EOF'
#!/bin/sh
exit 0
EOF
	done

chmod +x "$BIN_DIR"/*
printf 'test-auth-key\n' >"$WORK_DIR/authkey"
export PATH="$BIN_DIR:$PATH"
export TEST_ROOT="$WORK_DIR"
export TEST_LOG="$LOG_FILE"
export HEADSCALE_AUTO_ENROLL_LOCK_DIR="$LOCK_DIR"
export HEADSCALE_AUTO_ENROLL_TAILSCALE_INIT="$BIN_DIR/tailscale-init"
export HEADSCALE_AUTO_ENROLL_DONE_FILE="$WORK_DIR/auto-enroll.done"
export HEADSCALE_AUTO_ENROLL_STATE_READY_FILE="$WORK_DIR/tailscale-state.ready"
touch "$HEADSCALE_AUTO_ENROLL_STATE_READY_FILE"

run_case() {
	local scenario="$1" policy="$2" expected="$3" expected_command="$4"

	: >"$LOG_FILE"
	rm -f "$WORK_DIR/state-running" "$WORK_DIR/auto-enroll.done"
	case "$scenario" in
		first) printf '{"state":"no_backup"}\n' >"$GATE_FILE" ;;
		existing)
			touch "$WORK_DIR/state-running"
			printf '{"state":"no_backup"}\n' >"$GATE_FILE"
			;;
		restored) printf '{"state":"restored"}\n' >"$GATE_FILE" ;;
		*) echo "unknown test scenario: $scenario" >&2; exit 1 ;;
	esac

	TEST_ACCEPT_ROUTES="$policy" "$SCRIPT"
	grep -Fq "$expected_command " "$LOG_FILE" || {
		echo "$scenario did not use tailscale $expected_command" >&2
		cat "$LOG_FILE" >&2
		exit 1
	}
	grep -Fq -- "--accept-routes=$expected" "$LOG_FILE" || {
		echo "$scenario policy=$policy did not pass --accept-routes=$expected" >&2
		cat "$LOG_FILE" >&2
		exit 1
	}
	if [ "$expected_command" = set ] && grep -q '^up ' "$LOG_FILE"; then
		echo "$scenario should preserve its existing Tailnet identity" >&2
		exit 1
	fi
}

# The same canonical policy must be applied during a fresh enrollment, a
# preference reconcile for an existing node, and recovery of /data state.
for policy in 0 1; do
	case "$policy" in
		0) expected=false ;;
		1) expected=true ;;
	esac
	run_case first "$policy" "$expected" up
	run_case existing "$policy" "$expected" set
	run_case restored "$policy" "$expected" set
done

# Pre-policy and malformed configs fail safe to the established private-Mesh
# default, rather than silently disabling remote-route reachability.
run_case first '' true up
run_case first invalid true up

echo "tailscale accept-routes policy runtime test passed"
