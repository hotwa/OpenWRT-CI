#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export CONTAINER_BRIDGE_NFT_TESTING=1
. "$ROOT/files-container-runtime-test/usr/sbin/container-bridge-nft"
fail() { echo "FAIL: $*" >&2; exit 1; }
log() { printf '%s\n' "$*" >> "$TRACE"; }
mock_uci() {
    printf '%s\n' "$*" >> "$TRACE"
    if [[ "$*" == '-q get firewall.'* && "${MISSING_SECTIONS:-0}" = 1 ]]; then
        return 1
    fi
    [ "$*" != "${FAIL_UCI:-}" ]
}
UCI_CMD=mock_uci
data_mount_ready() { return 0; }
select_subnet() { SUBNET=10.250.0.0/24; }
reload_firewall() {
    printf '%s\n' reload >> "$TRACE"
    [ "${FAIL_RELOAD:-0}" = 0 ]
}
setup_case() {
    local folder="$TMP_ROOT/$1"
    mkdir -p "$folder"
    TRACE="$folder/trace"
    : > "$TRACE"
    STATE_DIR="$folder/state"
    SUBNET_FILE="$STATE_DIR/bridge-subnet"
    CNI_ACTIVE="$folder/cni/bridge.conflist"
    NFT_ACTIVE="$folder/nft/bridge.nft"
    CNI_TEMPLATE="$ROOT/files-container-runtime-test/usr/share/container-runtime/nerdctl-bridge.conflist.in"
    NFT_TEMPLATE="$ROOT/files-container-runtime-test/usr/share/container-runtime/container-bridge-nft.nft"
    FAIL_UCI=''
    FAIL_RELOAD=0
    MISSING_SECTIONS=0
}
setup_case success
enable_bridge || fail 'normal enable rejected'
grep -Fq '10.250.0.0/24' "$CNI_ACTIVE" || fail 'CNI not rendered'
grep -Fq '10.250.0.0/24' "$NFT_ACTIVE" || fail 'nft not rendered'
[ "$(cat "$SUBNET_FILE")" = 10.250.0.0/24 ] || fail 'subnet not persisted'
grep -qx reload "$TRACE" || fail 'firewall not reloaded'

setup_case missing-cni
CNI_TEMPLATE="$TMP_ROOT/absent-cni-template"
if enable_bridge; then fail 'missing CNI template accepted'; fi
! grep -qx reload "$TRACE" || fail 'reload after CNI failure'

setup_case missing-nft
NFT_TEMPLATE="$TMP_ROOT/absent-nft-template"
if enable_bridge; then fail 'missing nft template accepted'; fi
[ ! -e "$CNI_ACTIVE" ] || fail 'new CNI remains after nft failure'

# Fail each actual UCI write individually: a later successful write must not
# overwrite the failure status and let containerd start on a partial policy.
index=0
for operation in \
    'set firewall.container_bridge_nft.name=container_bridge_nft' \
    'set firewall.container_bridge_nft.device=ctrbr-nft0' \
    'set firewall.container_bridge_nft.input=ACCEPT' \
    'set firewall.container_bridge_nft.output=ACCEPT' \
    'set firewall.container_bridge_nft.forward=ACCEPT' \
    'set firewall.container_bridge_nft_to_wan.src=container_bridge_nft' \
    'set firewall.container_bridge_nft_to_wan.dest=wan' \
    'set firewall.container_bridge_nft_to_lan.src=container_bridge_nft' \
    'set firewall.container_bridge_nft_to_lan.dest=lan' \
    'set firewall.container_bridge_nft_to_tailscale.src=container_bridge_nft' \
    'set firewall.container_bridge_nft_to_tailscale.dest=tailscale' \
    'set firewall.lan_to_container_bridge_nft.src=lan' \
    'set firewall.lan_to_container_bridge_nft.dest=container_bridge_nft' \
    'set firewall.tailscale_to_container_bridge_nft.src=tailscale' \
    'set firewall.tailscale_to_container_bridge_nft.dest=container_bridge_nft' \
    'commit firewall'; do
    index=$((index + 1))
    setup_case "uci-$index"
    FAIL_UCI="$operation"
    if enable_bridge; then fail "UCI failure was swallowed: $operation"; fi
    [ ! -e "$CNI_ACTIVE" ] && [ ! -e "$NFT_ACTIVE" ] || fail 'generated policy remains after UCI failure'
    ! grep -qx reload "$TRACE" || fail 'reload after UCI failure'
done

for section in container_bridge_nft container_bridge_nft_to_wan container_bridge_nft_to_lan \
               container_bridge_nft_to_tailscale lan_to_container_bridge_nft tailscale_to_container_bridge_nft; do
    setup_case "create-$section"
    MISSING_SECTIONS=1
    kind=forwarding
    [ "$section" != container_bridge_nft ] || kind=zone
    FAIL_UCI="set firewall.$section=$kind"
    if enable_bridge; then fail "section creation failure was swallowed: $section"; fi
    [ ! -e "$CNI_ACTIVE" ] && [ ! -e "$NFT_ACTIVE" ] || fail 'generated policy remains after section creation failure'
    ! grep -qx reload "$TRACE" || fail 'reload after section creation failure'
done

setup_case reload-fails
FAIL_RELOAD=1
if enable_bridge; then fail 'firewall reload failure accepted'; fi
[ ! -e "$CNI_ACTIVE" ] && [ ! -e "$NFT_ACTIVE" ] || fail 'generated policy remains after reload failure'
grep -q 'rolling back' "$TRACE" || fail 'missing rollback log'

# Early failure can leave a previous generation behind; the init escape must
# warn about exactly this risk, not claim attachment was disabled.
setup_case stale-config
enable_bridge || fail 'cannot seed stale-config case'
select_subnet() { return 1; }
if enable_bridge; then fail 'subnet conflict accepted'; fi
[ -f "$CNI_ACTIVE" ] && [ -f "$NFT_ACTIVE" ] || fail 'unexpected early-failure cleanup contract change'
printf 'PASS: bridge enable failures, UCI writes, rollback and stale-config semantics\n'
