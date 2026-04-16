#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER="$ROOT_DIR/Scripts/patch_libiwrt_k612_cacheline_assert.sh"
PATCH_SOURCE="$ROOT_DIR/patches/libiwrt/999-fix-k612-net-device-cacheline-assert.patch"
TMP_DIR="$(mktemp -d)"
TREE_DIR="$TMP_DIR/wrt"
PATCH_TARGET="$TREE_DIR/target/linux/qualcommax/patches-6.12/999-fix-k612-net-device-cacheline-assert.patch"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[ -x "$PATCHER" ] || { echo "missing LiBwrt cacheline compatibility patcher"; exit 1; }
[ -f "$PATCH_SOURCE" ] || { echo "missing LiBwrt cacheline compatibility patch source"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }

mkdir -p "$TREE_DIR/target/linux/qualcommax/patches-6.12"

"$PATCHER" "$TREE_DIR" "davidtall/LiBwrt-openwrt-6.x" "k6.12-nss"

[ -f "$PATCH_TARGET" ] || {
	echo "LiBwrt cacheline compatibility patch was not injected into the source tree"
	exit 1
}

cmp -s "$PATCH_SOURCE" "$PATCH_TARGET" || {
	echo "LiBwrt cacheline compatibility patch content drifted during injection"
	exit 1
}

grep -q 'patch_libiwrt_k612_cacheline_assert.sh "\./wrt" "\$WRT_SOURCE" "\$WRT_BRANCH"' "$WORKFLOW" || {
	echo "WRT-CORE does not invoke the LiBwrt cacheline compatibility patcher"
	exit 1
}

echo "LiBwrt k6.12 cacheline patch guard test passed"
