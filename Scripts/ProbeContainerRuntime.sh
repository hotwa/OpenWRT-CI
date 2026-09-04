#!/bin/sh

# Runtime probe for a currently running OpenWrt device. Pass --run to exercise
# the default bridge+nft network, or --compose to exercise nerdctl compose with
# a temporary external bridge service. Pass --host only for an explicit final
# fallback check after bridge+nft has failed.

set +e
failures=0
run_smoke=0
run_compose=0
use_host=0
for argument in "$@"; do
	case "$argument" in
		--run) run_smoke=1 ;;
		--compose) run_compose=1 ;;
		--host) use_host=1 ;;
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
	if [ "$use_host" -eq 1 ]; then
		network_name=host
	else
		network_name=bridge
		if ! command -v container-bridge-nft >/dev/null 2>&1; then
			report "MISS bridge+nft helper: container-bridge-nft"
			failures=$((failures + 1))
		fi
	fi
	report "== ${network_name}-network smoke run =="
	nerdctl run --network "$network_name" --memory=128m --rm alpine:latest sh -c \
		'wget -T 15 -qO- https://www.google.com/generate_204 >/dev/null && wget -T 15 -qO- https://chatgpt.com/cdn-cgi/trace | grep -q "fl=" && proxy_ip=$(wget -T 15 -qO- https://api.ipify.org) && test -n "$proxy_ip" && echo "proxy_ip=$proxy_ip"' 2>&1
	[ "$?" -eq 0 ] || failures=$((failures + 1))
fi

if [ "$run_compose" -eq 1 ] && command -v nerdctl >/dev/null 2>&1; then
	compose_dir="/data/compose/.runtime-probe"
	compose_file="$compose_dir/compose.yaml"
	rm -rf "$compose_dir"
	mkdir -p "$compose_dir"
	if [ "$use_host" -eq 1 ]; then
		cat > "$compose_file" <<'EOF'
services:
  smoke:
    image: alpine:latest
    network_mode: host
    command: ["sh", "-c", "wget -T 15 -qO- https://www.google.com/generate_204 >/dev/null && wget -T 15 -qO- https://chatgpt.com/cdn-cgi/trace | grep -q fl= && wget -T 15 -qO- https://api.ipify.org"]
EOF
	else
		cat > "$compose_file" <<'EOF'
services:
  smoke:
    image: alpine:latest
    command: ["sh", "-c", "wget -T 15 -qO- https://www.google.com/generate_204 >/dev/null && wget -T 15 -qO- https://chatgpt.com/cdn-cgi/trace | grep -q fl= && wget -T 15 -qO- https://api.ipify.org"]
networks:
  default:
    external: true
    name: bridge
EOF
	fi
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
