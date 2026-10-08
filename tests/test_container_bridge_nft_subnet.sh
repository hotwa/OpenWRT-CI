#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files-container-runtime-test/usr/sbin/container-bridge-nft"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# 8. Syntax check
# ---------------------------------------------------------------------------
sh -n "$SCRIPT"

# ---------------------------------------------------------------------------
# Mock commands
# ---------------------------------------------------------------------------
MOCK_BIN="$TMP_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/ip" <<'MOCKEOF'
#!/bin/sh
# Mock ip command.
#   MOCK_IP_DEFAULT_ROUTE  - output for "ip -4 route show default"
#   MOCK_IP_ROUTE_GET      - default output for "ip -4 route get <gw>"
#   MOCK_IP_OVERRIDE_DIR   - if set, files named <gateway> override per-gw
args="$*"
case "$args" in
    *"route show table all"*)
        [ "${MOCK_IP_TABLE_FAIL:-0}" = 0 ] || exit 1
        [ -z "${MOCK_IP_ROUTES:-}" ] || printf '%s\n' "$MOCK_IP_ROUTES"
        ;;
    *"route show default"*)
        [ -n "${MOCK_IP_DEFAULT_ROUTE:-}" ] && printf '%s\n' "$MOCK_IP_DEFAULT_ROUTE"
        ;;
    *"addr show dev"*)
        [ -n "${MOCK_IP_ADDR_DEV:-}" ] && printf '%s\n' "$MOCK_IP_ADDR_DEV"
        ;;
    *"route get"*)
        if [ -n "${MOCK_IP_ROUTE_ERROR:-}" ]; then
            printf '%s\n' "$MOCK_IP_ROUTE_ERROR" >&2
            exit 2
        fi
        gateway=""
        for a in "$@"; do
            case "$a" in
                [0-9]*.[0-9]*.[0-9]*.[0-9]*) gateway="$a"; break ;;
            esac
        done
        override_dir="${MOCK_IP_OVERRIDE_DIR:-}"
        if [ -n "$override_dir" ] && [ -f "$override_dir/$gateway" ]; then
            cat "$override_dir/$gateway"
        elif [ -n "${MOCK_IP_ROUTE_GET:-}" ]; then
            printf '%s\n' "$MOCK_IP_ROUTE_GET"
        fi
        ;;
    *)
        printf 'mock-ip: unhandled args: %s\n' "$args" >&2
        exit 1
        ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/ip"

cat > "$MOCK_BIN/uci" <<'MOCKEOF'
#!/bin/sh
# Mock uci command.  Queries return optional env-controlled values; all
# other operations (set / commit / delete) are silent no-ops.
case "$*" in
    *"get network.lan.device"*)
        [ -n "${MOCK_UCI_LAN_DEVICE:-}" ] && printf '%s\n' "$MOCK_UCI_LAN_DEVICE"
        ;;
    *"get network.lan.ifname"*)
        [ -n "${MOCK_UCI_LAN_IFNAME:-}" ] && printf '%s\n' "$MOCK_UCI_LAN_IFNAME"
        ;;
    *)
        ;;
esac
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/uci"

# ---------------------------------------------------------------------------
# Source the script in TESTING mode (defines functions, skips dispatch).
# IP_CMD / UCI_CMD are fixed to the mocks for the entire test run.
# ---------------------------------------------------------------------------
export CONTAINER_BRIDGE_NFT_IP="$MOCK_BIN/ip"
export CONTAINER_BRIDGE_NFT_UCI="$MOCK_BIN/uci"
export CONTAINER_BRIDGE_NFT_TESTING=1
# shellcheck source=/dev/null
. "$SCRIPT"

pass_count=0
fail_count=0

assert_subnet() {
    # assert_subnet <description> <expected_subnet> <expect_success:0|1>
    local desc="$1" expected="$2" expect_success="$3"
    if select_subnet; then
        local rc=0
    else
        local rc=$?
    fi
    if [ "$expect_success" = "1" ] && [ "$rc" = "0" ] && [ "$SUBNET" = "$expected" ]; then
        echo "PASS: $desc (SUBNET=$SUBNET)"
        pass_count=$((pass_count + 1))
    elif [ "$expect_success" = "0" ] && [ "$rc" != "0" ]; then
        echo "PASS: $desc (correctly rejected, rc=$rc)"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (rc=$rc SUBNET=${SUBNET:-<unset>} expected=$expected expect_success=$expect_success)"
        fail_count=$((fail_count + 1))
    fi
}

setup_case() {
    # setup_case <name>  -> creates fresh dirs, resets all relevant vars
    local name="$1"
    local dir="$TMP_ROOT/case-$name"
    rm -rf "$dir"
    mkdir -p "$dir/state" "$dir/cni" "$dir/ip-overrides"

    # Script-internal variables (set directly, they are not readonly)
    STATE_DIR="$dir/state"
    SUBNET_FILE="$dir/state/bridge-subnet"
    CNI_ACTIVE="$dir/cni/nerdctl-bridge.conflist"
    SUBNET="$DEFAULT_SUBNET"

    # Mock behaviour env vars
    export MOCK_IP_DEFAULT_ROUTE=""
    export MOCK_IP_ROUTE_GET=""
    export MOCK_IP_ADDR_DEV=""
    export MOCK_IP_ROUTES=""
    export MOCK_IP_TABLE_FAIL=0
    export MOCK_IP_ROUTE_ERROR=""
    export MOCK_IP_OVERRIDE_DIR="$dir/ip-overrides"
    export MOCK_UCI_LAN_DEVICE=""
    export MOCK_UCI_LAN_IFNAME=""

    CASE_DIR="$dir"
}

# ===========================================================================
# 1. No default route + persisted subnet = allow (boot-time scenario)
# ===========================================================================
setup_case "01-no-default-persisted"
export MOCK_IP_DEFAULT_ROUTE=""
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
printf '10.250.0.0/24\n' > "$SUBNET_FILE"
assert_subnet "no default route + persisted 10.250.0.0/24 (boot race)" "10.250.0.0/24" 1

# ===========================================================================
# 2. No default route + candidate pool selection (no persisted file)
# ===========================================================================
setup_case "02-no-default-candidate"
export MOCK_IP_DEFAULT_ROUTE=""
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
# No persisted subnet file -> candidate loop, first candidate should win
assert_subnet "no default route, no persisted file -> first candidate" "10.250.0.0/24" 1

# ===========================================================================
# 3. Has default route + LAN conflict on persisted -> reject, pick next
# ===========================================================================
setup_case "03-default-lan-conflict"
export MOCK_IP_DEFAULT_ROUTE="default via 192.168.1.1 dev eth0"
# Persisted 10.250.0.0/24 conflicts with br-lan -> rejected
printf '10.250.0.1 dev br-lan src 10.250.0.1\n' > "$MOCK_IP_OVERRIDE_DIR/10.250.0.1"
# Next candidate 10.251.0.0/24 is safe (via route)
printf '10.251.0.1 via 192.168.1.1 dev eth0\n' > "$MOCK_IP_OVERRIDE_DIR/10.251.0.1"
printf '10.250.0.0/24\n' > "$SUBNET_FILE"
assert_subnet "default route + LAN conflict on persisted -> next candidate" "10.251.0.0/24" 1

# ===========================================================================
# 4. Has default route + via route = allow
# ===========================================================================
setup_case "04-default-via-allow"
export MOCK_IP_DEFAULT_ROUTE="default via 192.168.1.1 dev eth0"
export MOCK_IP_ROUTE_GET="10.250.0.1 via 192.168.1.1 dev eth0"
printf '10.250.0.0/24\n' > "$SUBNET_FILE"
assert_subnet "default route + via route on persisted" "10.250.0.0/24" 1

# ===========================================================================
# 5. Pending PPPoE default + synthetic unreachable must not reject candidates.
# ===========================================================================
setup_case "05-pppoe-unreachable-allow"
export MOCK_IP_DEFAULT_ROUTE="default via 100.64.1.1 dev pppoe-wan linkdown"
export MOCK_IP_ROUTES="$MOCK_IP_DEFAULT_ROUTE"
# All route lookups are unreachable while the PPP link is not ready.
printf 'unreachable 10.250.0.1 dev lo\n' > "$MOCK_IP_OVERRIDE_DIR/10.250.0.1"
printf 'unreachable 10.251.0.1 dev lo\n' > "$MOCK_IP_OVERRIDE_DIR/10.251.0.1"
printf 'unreachable 10.252.0.1 dev lo\n' > "$MOCK_IP_OVERRIDE_DIR/10.252.0.1"
printf 'unreachable 10.253.0.1 dev lo\n' > "$MOCK_IP_OVERRIDE_DIR/10.253.0.1"
printf 'unreachable 10.254.0.1 dev lo\n' > "$MOCK_IP_OVERRIDE_DIR/10.254.0.1"
printf 'unreachable 172.30.0.1 dev lo\n' > "$MOCK_IP_OVERRIDE_DIR/172.30.0.1"
printf 'unreachable 172.31.0.1 dev lo\n' > "$MOCK_IP_OVERRIDE_DIR/172.31.0.1"
assert_subnet "pending PPPoE default + unreachable -> first candidate" "10.250.0.0/24" 1

printf '10.250.0.0/24\n' > "$SUBNET_FILE"
assert_subnet "pending PPPoE default + persisted subnet -> reuse" "10.250.0.0/24" 1

# Negative policy routes must remain conflicts, with or without a WAN route.
for policy in unreachable blackhole prohibit throw; do
    setup_case "05-policy-$policy"
    export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
    export MOCK_IP_ROUTES="$policy 10.250.0.0/24"
    assert_subnet "$policy exact prefix -> next candidate" "10.251.0.0/24" 1
done

setup_case "05-policy-supernet"
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
export MOCK_IP_ROUTES="blackhole 10.0.0.0/8 table 100
prohibit 172.16.0.0/12 table 200"
assert_subnet "covering policies in other tables -> reject all" "" 0

setup_case "05-policy-child"
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
export MOCK_IP_ROUTES="throw 10.250.0.128/25 table 100"
assert_subnet "policy covering only upper half -> next candidate" "10.251.0.0/24" 1

setup_case "05-policy-host"
export MOCK_IP_ROUTE_GET="10.250.0.1 via 192.168.1.1 dev eth0"
export MOCK_IP_ROUTES="prohibit 10.250.0.128 table 100"
assert_subnet "policy host route away from gateway -> next candidate" "10.251.0.0/24" 1

setup_case "05-policy-default"
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
export MOCK_IP_ROUTES="unreachable default table 100"
assert_subnet "explicit negative default policy -> reject all" "" 0

setup_case "05-policy-unrelated"
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
export MOCK_IP_ROUTES="blackhole 10.249.0.0/24 table 100"
assert_subnet "unrelated policy does not block boot" "10.250.0.0/24" 1

setup_case "05-table-query-failed"
export MOCK_IP_ROUTE_GET="10.250.0.1 via 192.168.1.1 dev eth0"
export MOCK_IP_TABLE_FAIL=1
assert_subnet "route inventory unavailable -> fail closed" "" 0

setup_case "05-network-unreachable-stderr"
export MOCK_IP_ROUTE_ERROR="RTNETLINK answers: Network is unreachable"
assert_subnet "no WAN route with iproute2 stderr only -> allow" "10.250.0.0/24" 1

setup_case "05-busybox-network-unreachable-stderr"
export MOCK_IP_ROUTE_ERROR="ip: RTNETLINK answers: Network is unreachable"
assert_subnet "no WAN route with BusyBox ip stderr only -> allow" "10.250.0.0/24" 1

setup_case "05-unknown-error"
export MOCK_IP_ROUTE_ERROR="RTNETLINK answers: Operation not permitted"
assert_subnet "unrecognised route lookup failure -> fail closed" "" 0

setup_case "05-empty-result"
assert_subnet "empty route lookup -> fail closed" "" 0

setup_case "05-pppoe-online"
export MOCK_IP_ROUTE_GET="10.250.0.1 dev pppoe-wan src 100.64.1.2"
export MOCK_IP_ROUTES="default dev pppoe-wan scope link"
assert_subnet "established point-to-point PPPoE default -> allow" "10.250.0.0/24" 1

setup_case "05-pppoe-not-default"
export MOCK_IP_ROUTE_GET="10.250.0.1 dev pppoe-other"
assert_subnet "PPP device without matching default -> reject" "" 0

setup_case "05-connected-child"
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
export MOCK_IP_ROUTES="10.250.0.128/25 dev br-lan table 100 proto kernel scope link"
assert_subnet "connected LAN child prefix -> next candidate" "10.251.0.0/24" 1

setup_case "05-routed-lan-child"
export MOCK_IP_ROUTE_GET="10.250.0.1 via 192.168.1.1 dev eth0"
export MOCK_IP_ROUTES="10.250.0.128/25 via 192.168.1.254 dev br-lan table 100"
assert_subnet "routed LAN child prefix -> next candidate" "10.251.0.0/24" 1

setup_case "05-local-other-host"
export MOCK_IP_ROUTE_GET="10.250.0.1 via 192.168.1.1 dev eth0"
export MOCK_IP_ROUTES="local 10.250.0.128 dev lo table local proto kernel scope host"
assert_subnet "local address away from gateway -> next candidate" "10.251.0.0/24" 1

setup_case "05-local-own-inventory"
export MOCK_IP_ROUTE_GET="local 10.250.0.1 dev lo table local src 10.250.0.1"
export MOCK_IP_ROUTES="local 10.250.0.1 dev ctrbr-nft0 table local proto kernel scope host
10.250.0.0/24 dev ctrbr-nft0 proto kernel scope link"
export MOCK_IP_ADDR_DEV="10.250.0.1/24 brd 10.250.0.255 scope global ctrbr-nft0"
assert_subnet "own bridge local/connected inventory -> reuse" "10.250.0.0/24" 1

setup_case "05-protected-last-token"
export MOCK_IP_ROUTE_GET="10.250.0.1 via 192.168.1.1 dev br-lan"
assert_subnet "protected device at end of via route -> reject" "" 0

setup_case "05-synthetic-blackhole"
export MOCK_IP_ROUTE_GET="blackhole 10.250.0.1"
assert_subnet "explicit blackhole lookup is never a WAN boot allowance" "" 0

# ===========================================================================
# 6. tailscale0 / nikki / tun* conflict = reject (even without default route)
# ===========================================================================

# 6a. tailscale0
setup_case "06a-tailscale0"
export MOCK_IP_DEFAULT_ROUTE=""
export MOCK_IP_ROUTE_GET="10.250.0.1 dev tailscale0 src 100.64.0.1"
assert_subnet "no default route + route via tailscale0 -> reject" "" 0

# 6b. nikki
setup_case "06b-nikki"
export MOCK_IP_DEFAULT_ROUTE=""
export MOCK_IP_ROUTE_GET="10.250.0.1 dev nikki src 10.250.0.1"
assert_subnet "no default route + route via nikki -> reject" "" 0

# 6c. tun0
setup_case "06c-tun0"
export MOCK_IP_DEFAULT_ROUTE=""
export MOCK_IP_ROUTE_GET="10.250.0.1 dev tun0 src 10.8.0.1"
assert_subnet "no default route + route via tun0 -> reject" "" 0

# 6d. Custom LAN device (not br-lan) via uci
setup_case "06d-custom-lan"
export MOCK_IP_DEFAULT_ROUTE="default via 192.168.1.1 dev eth0"
export MOCK_UCI_LAN_DEVICE="eth1"
export MOCK_IP_ROUTE_GET="10.250.0.1 dev eth1 src 192.168.2.1"
assert_subnet "default route + custom LAN device eth1 conflict -> reject" "" 0

# ===========================================================================
# 7. CNI config conflict = reject
# ===========================================================================
setup_case "07-cni-conflict"
export MOCK_IP_DEFAULT_ROUTE=""
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
# Place another CNI config in the same directory that uses the same subnet
cat > "$CASE_DIR/cni/other-network.conflist" <<'CNIEOF'
{
  "cniVersion": "1.0.0",
  "name": "other",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "other-br0",
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "10.250.0.0/24"}]]
      }
    }
  ]
}
CNIEOF
assert_subnet "no default route + CNI config overlap 10.250.0.0/24 -> skip to 10.251.0.0/24" "10.251.0.0/24" 1

# 7b. Verify that a *different* subnet in the other CNI config does not
#     block the candidate (the conflict check is subnet-specific).
setup_case "07b-cni-no-conflict"
export MOCK_IP_DEFAULT_ROUTE=""
export MOCK_IP_ROUTE_GET="unreachable 10.250.0.1 dev lo"
cat > "$CASE_DIR/cni/other-network.conflist" <<'CNIEOF'
{
  "cniVersion": "1.0.0",
  "name": "other",
  "plugins": [
    {
      "type": "bridge",
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "10.99.0.0/24"}]]
      }
    }
  ]
}
CNIEOF
assert_subnet "no default route + unrelated CNI subnet -> allow 10.250.0.0/24" "10.250.0.0/24" 1

# ===========================================================================
# 8. local route (gateway held by own bridge) = allow reuse of persisted
# ===========================================================================
setup_case "08-local-own-bridge"
export MOCK_IP_DEFAULT_ROUTE="default via 192.168.1.1 dev eth0"
# "ip route get" returns local because ctrbr-nft0 still holds the gateway
printf 'local 10.250.0.1 dev lo table local src 10.250.0.1 uid 0\n' > "$MOCK_IP_OVERRIDE_DIR/10.250.0.1"
# The address really lives on our bridge -> reuse persisted subnet
export MOCK_IP_ADDR_DEV="10.250.0.1/24 brd 10.250.0.255 scope global ctrbr-nft0"
printf '10.250.0.0/24\n' > "$SUBNET_FILE"
assert_subnet "default route + local route (gateway on own bridge) -> reuse persisted" "10.250.0.0/24" 1

# 8b. local route but the address is NOT on our bridge = reject persisted
setup_case "08b-local-other-iface"
export MOCK_IP_DEFAULT_ROUTE="default via 192.168.1.1 dev eth0"
printf 'local 10.250.0.1 dev lo table local src 10.250.0.1 uid 0\n' > "$MOCK_IP_OVERRIDE_DIR/10.250.0.1"
export MOCK_IP_ADDR_DEV=""
printf '10.250.0.0/24\n' > "$SUBNET_FILE"
assert_subnet "default route + local route not on our bridge -> reject persisted" "" 0

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "===== container-bridge-nft subnet tests: $pass_count passed, $fail_count failed ====="
if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
echo "All container-bridge-nft subnet tests passed"
