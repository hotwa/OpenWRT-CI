#!/bin/sh

# Read-only runtime probe for a currently running OpenWrt device. Pass --run
# to additionally pull and run the small host-network smoke container, or
# --compose to exercise nerdctl compose with a temporary host-network service.

set +e
failures=0
run_smoke=0
run_compose=0
for argument in "$@"; do
	case "$argument" in
		--run) run_smoke=1 ;;
		--compose) run_compose=1 ;;
		*) printf '%s\n' "unknown argument: $argument"; failures=$((failures + 1)) ;;
	esac
done

report() {
	printf '%s\n' "$*"
}

check_command() {
	command -v "$1" >/dev/null 2>&1
	if [ "$?" -eq 0 ]; then
		report "OK command: $1 -> $(command -v "$1")"
	else
		report "MISS command: $1"
		failures=$((failures + 1))
	fi
}

report "== OpenWrt container runtime probe =="
report "board=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo unknown)"
report "kernel=$(uname -a)"
report "== binaries =="
for command_name in containerd containerd-shim-runc-v2 ctr nerdctl runc; do
	check_command "$command_name"
done
for command_name in containerd nerdctl runc; do
	if command -v "$command_name" >/dev/null 2>&1; then
		report "version $command_name:"
		"$command_name" --version 2>&1 | sed -n '1,3p'
	fi
done

report "== /data mount and storage =="
awk '$2 == "/data" { print "data_mount=" $0; found = 1 } END { if (!found) print "data_mount=MISSING" }' /proc/mounts
df -h / /data /run 2>&1
for path in /data/containerd /data/containerd/root /data/containerd/nerdctl /data/npm /data/node-compile-cache; do
	if [ -e "$path" ]; then
		report "path=$path exists"
	else
		report "path=$path missing"
	fi
done

report "== cgroup v2 =="
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
	report "cgroup.controllers=$(cat /sys/fs/cgroup/cgroup.controllers)"
	report "cgroup.subtree_control=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null)"
else
	report "cgroup v2 files are missing"
	failures=$((failures + 1))
fi

report "== network backend =="
iptables -V 2>&1 | sed -n '1,2p'
nft list tables 2>&1 | sed -n '1,30p'

if [ "$run_smoke" -eq 1 ] && command -v nerdctl >/dev/null 2>&1; then
	report "== host-network smoke run =="
	nerdctl run --network host --rm alpine:latest echo ok 2>&1
	[ "$?" -eq 0 ] || failures=$((failures + 1))
fi

if [ "$run_compose" -eq 1 ] && command -v nerdctl >/dev/null 2>&1; then
	compose_dir="/tmp/nerdctl-compose-probe"
	compose_file="$compose_dir/compose.yaml"
	rm -rf "$compose_dir"
	mkdir -p "$compose_dir"
	cat > "$compose_file" <<'EOF'
services:
  smoke:
    image: alpine:latest
    network_mode: host
    command: ["sh", "-c", "echo compose-ok"]
EOF
	report "== nerdctl compose smoke run =="
	nerdctl compose -f "$compose_file" up 2>&1
	[ "$?" -eq 0 ] || failures=$((failures + 1))
	nerdctl compose -f "$compose_file" down --remove-orphans 2>&1
	rm -rf "$compose_dir"
fi

if [ "$failures" -eq 0 ]; then
	report "PROBE_RESULT=pass"
else
	report "PROBE_RESULT=fail failures=$failures"
fi
exit "$failures"
