#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
WORKFLOW="$ROOT_DIR/.github/workflows/RE-CONTAINER-RUNTIME-TEST.yml"
OVERLAY="$ROOT_DIR/files-container-runtime-test"

[ -f "$CORE" ] || { echo "missing WRT-CORE workflow" >&2; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing container test workflow" >&2; exit 1; }
[ -f "$OVERLAY/etc/containerd/containerd-test.toml" ] || exit 1
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
grep -Fq 'nerdctl-full-' "$ROOT_DIR/Scripts/fetch_container_runtime.sh"
grep -Fq 'SHA256SUMS' "$ROOT_DIR/Scripts/fetch_container_runtime.sh"
grep -Fq 'for cni_plugin in bridge host-local ipvlan loopback tuning' "$ROOT_DIR/Scripts/fetch_container_runtime.sh"
grep -Fq 'CONFIG_PACKAGE_kmod-ipvlan=y' "$ROOT_DIR/.github/workflows/WRT-CORE.yml"
grep -Fq -- '--compose' "$ROOT_DIR/Scripts/ProbeContainerRuntime.sh"
grep -Fq 'unset NODE_COMPILE_CACHE' "$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"

echo "RE-CS-07 container runtime guards passed"
