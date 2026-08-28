#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
PROFILE_NODE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
PROFILE_UPDATE="$ROOT_DIR/files/etc/profile.d/30-agent-update-check.sh"
AGENT_MANIFEST="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
AGENT_LOCK="$ROOT_DIR/Scripts/node-agent-runtime/package-lock.json"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$FETCH_SCRIPT" ] || { echo "missing fetch_node_runtime.sh"; exit 1; }
[ -f "$PROFILE_NODE" ] || { echo "missing 20-node-agent.sh"; exit 1; }
[ -f "$PROFILE_UPDATE" ] || { echo "missing 30-agent-update-check.sh"; exit 1; }
[ -f "$AGENT_MANIFEST" ] || { echo "missing node-agent-runtime/package.json"; exit 1; }
[ -f "$AGENT_LOCK" ] || { echo "missing node-agent-runtime/package-lock.json"; exit 1; }

grep -q '\$GITHUB_WORKSPACE/Scripts/fetch_node_runtime.sh' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not run fetch_node_runtime.sh"
  exit 1
}

FETCH_LINE="$(grep -n '\$GITHUB_WORKSPACE/Scripts/fetch_node_runtime.sh' "$WORKFLOW" | head -n1 | cut -d: -f1)"
COPY_LINE="$(grep -n 'cp -rf ./files/. ./wrt/files/' "$WORKFLOW" | head -n1 | cut -d: -f1)"
[ -n "$FETCH_LINE" ] || { echo "missing fetch script line number"; exit 1; }
[ -n "$COPY_LINE" ] || { echo "missing files copy line number"; exit 1; }
[ "$FETCH_LINE" -lt "$COPY_LINE" ] || {
  echo "WRT-CORE.yml runs fetch_node_runtime.sh after files/ has already been staged"
  exit 1
}

grep -q 'linux-arm64-musl' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not support linux-arm64-musl"
  exit 1
}

grep -q 'linux-x64-musl' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not support linux-x64-musl"
  exit 1
}

grep -q 'node-agent-runtime' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not reference the node-agent-runtime manifest directory"
  exit 1
}

grep -q 'npm ci' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not install the locked agent runtime with npm ci"
  exit 1
}

for pkg in \
  "opencode-ai" \
  "@earendil-works/pi-coding-agent" \
  "@aaronkyriesenbach/pi-package-manager" \
  "btw-pi" \
  "pi-plan-mode" \
  "pi-web-search" \
  "pi-wechat-assistant" \
  "@tarquinen/opencode-dcp" \
  "@mohak34/opencode-notifier" \
  "opencode-conductor-plugin" \
  "hermes-agent" \
  "pnpm"; do
  grep -q "$pkg" "$AGENT_MANIFEST" || {
    echo "node-agent-runtime/package.json missing package: $pkg"
    exit 1
  }
done

for bin in node npm npx pnpm opencode pi hermes; do
  grep -q "$bin" "$FETCH_SCRIPT" || {
    echo "fetch_node_runtime.sh missing symlink handling for $bin"
    exit 1
  }
done

grep -q '/opt/node/bin' "$PROFILE_NODE" || {
  echo "20-node-agent.sh does not export /opt/node/bin in PATH"
  exit 1
}

grep -q 'pnpm update -g --latest' "$PROFILE_UPDATE" || {
  echo "30-agent-update-check.sh does not instruct pnpm update -g --latest"
  exit 1
}

echo "node runtime and agent preload guard test passed"
