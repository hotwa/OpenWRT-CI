#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
WORKFLOW="$ROOT_DIR/.github/workflows/RE-CONTAINER-RUNTIME-TEST.yml"
OVERLAY="$ROOT_DIR/files-container-runtime-test"

[ -f "$CORE" ] || { echo "missing WRT-CORE workflow" >&2; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing container test workflow" >&2; exit 1; }
[ -f "$OVERLAY/etc/containerd/containerd-test.toml" ] || exit 1
[ -f "$OVERLAY/usr/share/container-runtime/nerdctl-bridge.conflist.in" ] || exit 1
[ -f "$OVERLAY/usr/share/container-runtime/container-bridge-nft.nft" ] || exit 1
[ "$(git -C "$ROOT_DIR" ls-files --stage -- files-container-runtime-test/usr/sbin/container-bridge-nft | awk '{print $1}')" = 100755 ] || {
	echo "container bridge helper must be executable in Git" >&2
	exit 1
}
[ "$(git -C "$ROOT_DIR" ls-files --stage -- files-container-runtime-test/etc/init.d/containerd-test | awk '{print $1}')" = 100755 ] || {
	echo "containerd test init script must be executable in Git" >&2
	exit 1
}
[ "$(git -C "$ROOT_DIR" ls-files --stage -- files-container-runtime-test/etc/uci-defaults/97-containerd-test-enable | awk '{print $1}')" = 100755 ] || {
	echo "containerd test uci-defaults script must be executable in Git" >&2
	exit 1
}

grep -Fq 'WRT_CONTAINER_RUNTIME_TEST:' "$CORE"
grep -Fq 'WRT_CONTAINER_RUNTIME_TEST: ${{inputs.WRT_CONTAINER_RUNTIME_TEST}}' "$CORE"
grep -Fq 'files-container-runtime-test/. ./wrt/files/' "$CORE"
grep -Fq 'container runtime is allowed only for jdcloud_re-cs-02 and jdcloud_re-cs-07' "$CORE"
grep -Fq 'WRT_EMMC_DATA_PROVISIONING: true' "$WORKFLOW"
grep -Fq 'WRT_CONTAINER_RUNTIME_TEST: true' "$WORKFLOW"
grep -Fq 'type: choice' "$WORKFLOW"
grep -Fq 'WRT_CONTAINER_RUNTIME_MODE: ${{ inputs.CONTAINER_RUNTIME_MODE || '\''prebuilt'\'' }}' "$WORKFLOW"
grep -Fq 'WRT_CONTAINER_RUNTIME_VERSION: ${{ inputs.CONTAINER_RUNTIME_VERSION }}' "$WORKFLOW"

grep -Fq "if: inputs.TARGET == 'all' || inputs.TARGET == 're-cs-02'" "$WORKFLOW"
grep -Fq "if: inputs.TARGET == 'all' || inputs.TARGET == 're-cs-07'" "$WORKFLOW"
grep -Fq 'WRT_CONFIG: IPQ60XX-RE-CS-02' "$WORKFLOW"
grep -Fq 'WRT_EXPECTED_DEVICE: jdcloud_re-cs-02' "$WORKFLOW"
grep -Fq 'WRT_CONFIG: IPQ60XX-RE-CS-07-NOWIFI' "$WORKFLOW"
grep -Fq 'WRT_EXPECTED_DEVICE: jdcloud_re-cs-07' "$WORKFLOW"
grep -Fq 'WRT_CONTAINER_RUNTIME_TEST: true' "$WORKFLOW"
grep -Fq 'type: choice' "$WORKFLOW"
grep -Fq 'WRT_CONTAINER_RUNTIME_MODE: ${{ inputs.CONTAINER_RUNTIME_MODE || '\''prebuilt'\'' }}' "$WORKFLOW"
grep -Fq 'WRT_CONTAINER_RUNTIME_VERSION: ${{ inputs.CONTAINER_RUNTIME_VERSION }}' "$WORKFLOW"

for obsolete in RE-CS-02-CONTAINER-TEST.yml RE-CS-07-CONTAINER-TEST.yml; do
	[ ! -e "$ROOT_DIR/.github/workflows/$obsolete" ] || {
		echo "obsolete duplicate workflow remains: $obsolete" >&2
		exit 1
	}
done

if grep -Fq 'WRT_CONTAINER_RUNTIME_TEST: true' "$ROOT_DIR/.github/workflows/RE-Mesh-BUILD.yml"; then
	echo "normal RE-Mesh workflow must not enable the experimental runtime" >&2
	exit 1
fi
if grep -Fq 'WRT_CONTAINER_RUNTIME_TEST: true' "$ROOT_DIR/.github/workflows/RE-CS-07-BUILD.yml"; then
	echo "normal RE-CS-07 workflow must not enable the experimental runtime" >&2
	exit 1
fi

if grep -Eq 'CONFIG_PACKAGE_(docker|dockerd|luci-app-dockerman)=y' "$WORKFLOW"; then
	echo "container test must not add Docker packages" >&2
	exit 1
fi

bash -n "$OVERLAY/etc/init.d/containerd-test"
bash -n "$OVERLAY/etc/uci-defaults/97-containerd-test-enable"
sh -n "$OVERLAY/usr/sbin/container-bridge-nft"
grep -Fq 'version = 3' "$OVERLAY/etc/containerd/containerd-test.toml"
grep -Fq 'root = "/data/containerd/root"' "$OVERLAY/etc/containerd/containerd-test.toml"
grep -Fq 'state = "/run/containerd"' "$OVERLAY/etc/containerd/containerd-test.toml"
grep -Fq 'address = "/run/containerd/containerd.sock"' "$OVERLAY/etc/containerd/containerd-test.toml"
grep -Fq 'data_root = "/data/containerd/nerdctl"' "$OVERLAY/etc/nerdctl/nerdctl.toml"
grep -Fq 'refusing to start' "$OVERLAY/etc/init.d/containerd-test"
if grep -Eq 'mkfs|format' "$OVERLAY/etc/init.d/containerd-test" "$OVERLAY/etc/uci-defaults/97-containerd-test-enable"; then
	echo "container runtime overlay must never format storage" >&2
	exit 1
fi

[ -x "$ROOT_DIR/Scripts/fetch_container_runtime.sh" ] || exit 1
[ -x "$ROOT_DIR/Scripts/ProbeContainerRuntime.sh" ] || exit 1
bash -n "$ROOT_DIR/Scripts/fetch_container_runtime.sh"
sh -n "$ROOT_DIR/Scripts/ProbeContainerRuntime.sh"
grep -Fq 'nerdctl run --network "$network_name"' "$ROOT_DIR/Scripts/ProbeContainerRuntime.sh"
grep -Fq 'compose_dir="/data/compose/.runtime-probe"' "$ROOT_DIR/Scripts/ProbeContainerRuntime.sh"
grep -Fq 'name: bridge' "$ROOT_DIR/Scripts/ProbeContainerRuntime.sh"
grep -Fq 'nerdctl-full-' "$ROOT_DIR/Scripts/fetch_container_runtime.sh"
grep -Fq 'SHA256SUMS' "$ROOT_DIR/Scripts/fetch_container_runtime.sh"
grep -Fq 'for cni_plugin in bridge host-local loopback tuning' "$ROOT_DIR/Scripts/fetch_container_runtime.sh"
if grep -R -n -E 'CONFIG_PACKAGE_kmod-ipvlan|for cni_plugin in .*ipvlan|/ipvlan' \
	"$ROOT_DIR/.github/workflows/WRT-CORE.yml" \
	"$ROOT_DIR/Scripts/fetch_container_runtime.sh" \
	"$ROOT_DIR/files-container-runtime-test" \
	"$ROOT_DIR/files/etc/multica/openwrt-agent.md" >/dev/null 2>&1; then
	echo "container runtime firmware must not include the unsupported ipvlan path" >&2
	exit 1
fi
grep -Fq -- '--compose' "$ROOT_DIR/Scripts/ProbeContainerRuntime.sh"
grep -Fq 'unset NODE_COMPILE_CACHE' "$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
grep -Fq '"name": "bridge"' "$OVERLAY/usr/share/container-runtime/nerdctl-bridge.conflist.in"
grep -Fq '"nerdctl/default-network": "true"' "$OVERLAY/usr/share/container-runtime/nerdctl-bridge.conflist.in"
grep -Fq '"bridge": "ctrbr-nft0"' "$OVERLAY/usr/share/container-runtime/nerdctl-bridge.conflist.in"
grep -Fq '"ipMasq": false' "$OVERLAY/usr/share/container-runtime/nerdctl-bridge.conflist.in"
if grep -Eq '"type": "(portmap|firewall)"|iptables' "$OVERLAY/usr/share/container-runtime/nerdctl-bridge.conflist.in"; then
	echo "bridge+nft CNI config must not invoke iptables plugins" >&2
	exit 1
fi
grep -Fq '__CONTAINER_SUBNET__' "$OVERLAY/usr/share/container-runtime/container-bridge-nft.nft"
grep -Fq '__CONTAINER_SUBNET__' "$OVERLAY/usr/share/container-runtime/nerdctl-bridge.conflist.in"
grep -Fq 'DEFAULT_SUBNET="10.250.0.0/24"' "$OVERLAY/usr/sbin/container-bridge-nft"
grep -Fq 'no unused container subnet is available' "$OVERLAY/usr/sbin/container-bridge-nft"
grep -Fq 'refusing to enable: /data is not a real ext4/f2fs block mount' "$OVERLAY/usr/sbin/container-bridge-nft"
grep -Fq 'container-bridge-nft enable' "$OVERLAY/etc/init.d/containerd-test"
grep -Fq 'NFT_ACTIVE="/etc/nftables.d/99-container-bridge-nft.nft"' "$OVERLAY/usr/sbin/container-bridge-nft"
grep -Fq 'BRIDGE="ctrbr-nft0"' "$OVERLAY/usr/sbin/container-bridge-nft"
grep -Fq 'meta mark set meta mark & 0xffffff81 | 0x00000081' "$OVERLAY/usr/share/container-runtime/container-bridge-nft.nft"
grep -Fq 'redirect to :1053' "$OVERLAY/usr/share/container-runtime/container-bridge-nft.nft"
grep -Fq 'redirect to :7891' "$OVERLAY/usr/share/container-runtime/container-bridge-nft.nft"
if grep -Eq 'add_device|add_dynamic|lan_inbound_interface|network\.containerd' "$OVERLAY/usr/sbin/container-bridge-nft"; then
	echo "bridge helper must not let netifd or Nikki own the CNI bridge" >&2
	exit 1
fi
grep -Fq '"$DATA_ROOT/compose"' "$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
grep -Fq 'bridge+nft' "$ROOT_DIR/files/etc/multica/openwrt-agent.md"
grep -Fq '/data/compose/<service>/compose.yaml' "$ROOT_DIR/files/etc/multica/openwrt-agent.md"
grep -Fq 'WRT_CONTAINER_RUNTIME_TEST' "$WORKFLOW"

echo "RE-CS-07 container runtime guards passed"
