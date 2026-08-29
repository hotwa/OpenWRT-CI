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

grep -q 'fix_opencode_entrypoint' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not replace the host-arch opencode entrypoint"
  exit 1
}

grep -q 'opencode-linux-arm64-musl' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not select the arm64 musl opencode binary"
  exit 1
}

grep -q 'rm -rf "\$NODE_LIB_DIR"/opencode-linux-' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh keeps the install-only opencode platform packages in the rootfs"
  exit 1
}

grep -q 'elf_machine_id' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not verify the opencode entrypoint architecture"
  exit 1
}

grep -q 'prune_agent_runtime_deadweight' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not prune agent runtime dead weight"
  exit 1
}

for deadweight in \
  'runtime/hermes-agent/tests' \
  'runtime/hermes-agent/website' \
  'runtime/hermes-agent/venv' \
  'runtime/python' \
  '.uv_bin' \
  '.hermes-agent-runtime.json'; do
  grep -q "$deadweight" "$FETCH_SCRIPT" || {
    echo "fetch_node_runtime.sh does not prune the runner-baked hermes path: $deadweight"
    exit 1
  }
done

grep -q 'prune_foreign_platform_builds' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not prune foreign-arch prebuilt native modules"
  exit 1
}

grep -q 'verify_agent_runtime_arch "\$npm_arch"' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not verify the agent runtime architecture before shipping"
  exit 1
}

grep -q 'agent-update.env' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not publish the pinned hermes version for device provisioning"
  exit 1
}

if grep -q 'cat >"\$PROFILE_DIR' "$FETCH_SCRIPT"; then
  echo "fetch_node_runtime.sh regenerates profile.d scripts that are already committed under files/"
  exit 1
fi

# bash -n does not resolve function names, so a helper deleted while main()
# still called it would only surface as a 127 in the middle of a build.
MAIN_CALLS="$(awk '/^main\(\) \{/{inside=1; next} inside && /^\}/{inside=0}
  inside && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ { print $1 }' "$FETCH_SCRIPT")"
while IFS= read -r called; do
  [ -n "$called" ] || continue
  case "$called" in
    if|then|else|elif|fi|for|while|until|do|done|case|esac|local|export|set|trap|return|break|continue) continue ;;
  esac
  grep -Eq "^[[:space:]]*${called}\(\)[[:space:]]*[({]" "$FETCH_SCRIPT" ||
    command -v "$called" >/dev/null 2>&1 || {
    echo "fetch_node_runtime.sh main() calls undefined function: $called"
    exit 1
  }
done <<EOF
$MAIN_CALLS
EOF

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

grep -q '/data/node/bin' "$PROFILE_NODE" || {
  echo "20-node-agent.sh does not let /data installs shadow the read-only baked runtime"
  exit 1
}

grep -q 'npm i -g --prefix /data/node' "$PROFILE_UPDATE" || {
  echo "30-agent-update-check.sh does not advertise the writable-prefix upgrade command"
  exit 1
}

if grep -q '/opt/node/bin/opencode --version' "$PROFILE_UPDATE"; then
  echo "30-agent-update-check.sh reports the baked version instead of the PATH-resolved one"
  exit 1
fi

echo "node runtime and agent preload guard test passed"
