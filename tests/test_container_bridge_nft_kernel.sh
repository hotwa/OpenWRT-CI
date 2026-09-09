#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Exercise the real kernel/iproute2 stdout/stderr forms in an anonymous network
# namespace. No routes, links or services in the host namespace are changed.
if ! command -v unshare >/dev/null || ! command -v ip >/dev/null ||
   ! unshare -n true 2>/dev/null; then
    echo 'SKIP: kernel bridge guard checks require an isolated network namespace'
    exit 0
fi
IMPLEMENTATIONS=(system)
if command -v busybox >/dev/null; then IMPLEMENTATIONS+=(busybox); fi
for implementation in "${IMPLEMENTATIONS[@]}"; do
    TEST_SHELL=(/bin/sh)
    if [ "$implementation" = busybox ]; then TEST_SHELL=(busybox sh); fi
    unshare -n "${TEST_SHELL[@]}" -s -- "$ROOT" "$implementation" <<'SH'
set -eu
export CONTAINER_BRIDGE_NFT_TESTING=1
. "$1/files-container-runtime-test/usr/sbin/container-bridge-nft"
UCI_CMD=true
CNI_ACTIVE=/nonexistent-container-guard-test/bridge.conflist
if command -v busybox >/dev/null; then
    awk() { busybox awk "$@"; }
fi
allowed() {
    candidate_route_is_safe 10.250.0.0/24 10.250.0.1 || { echo "FAIL: $1"; exit 1; }
}
rejected() {
    if candidate_route_is_safe 10.250.0.0/24 10.250.0.1; then
        echo "FAIL: $1"
        exit 1
    fi
}
allowed 'no WAN route (iproute2 stderr-only error)'
ip route add blackhole 10.0.0.0/8 table 100
rejected 'covering blackhole in non-main table'
ip route del blackhole 10.0.0.0/8 table 100
ip route add prohibit 10.250.0.128/25 table 200
rejected 'child prohibit in non-main table'
ip route del prohibit 10.250.0.128/25 table 200
ip route add throw 10.250.0.128 table 100
rejected 'single-host throw away from gateway'
ip route del throw 10.250.0.128 table 100
ip route add unreachable default table 100
rejected 'explicit unreachable default'
ip route del unreachable default table 100

# A dummy link reproduces a no-via default route form, not PPP negotiation.
ip link add pppoe-test type dummy
ip addr add 192.0.2.2/32 dev pppoe-test
ip link set pppoe-test up
ip route add default dev pppoe-test
allowed 'point-to-point-shaped default without via'
ip addr add 10.250.0.128/32 dev lo
rejected 'local address away from gateway'
ip addr del 10.250.0.128/32 dev lo
ip link add br-lan type dummy
ip addr add 10.250.0.129/25 dev br-lan
ip link set br-lan up
rejected 'LAN overlap away from tested gateway'
echo "PASS: isolated real-kernel routes ($2 shell) and BusyBox-compatible overlap checks"
SH
done
