#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
PROFILE_NODE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
PROFILE_UPDATE="$ROOT_DIR/files/etc/profile.d/30-agent-update-check.sh"
AGENT_MANIFEST="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
AGENT_LOCK="$ROOT_DIR/Scripts/node-agent-runtime/package-lock.json"
HERMES_CORE_BUILDER="$ROOT_DIR/Scripts/build_hermes_core.sh"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$FETCH_SCRIPT" ] || { echo "missing fetch_node_runtime.sh"; exit 1; }
[ -f "$PROFILE_NODE" ] || { echo "missing 20-node-agent.sh"; exit 1; }
[ -f "$PROFILE_UPDATE" ] || { echo "missing 30-agent-update-check.sh"; exit 1; }
[ -f "$AGENT_MANIFEST" ] || { echo "missing node-agent-runtime/package.json"; exit 1; }
[ -f "$AGENT_LOCK" ] || { echo "missing node-agent-runtime/package-lock.json"; exit 1; }
[ -f "$HERMES_CORE_BUILDER" ] || { echo "missing build_hermes_core.sh"; exit 1; }

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

grep -q -- '--ignore-scripts' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh must skip host hermes-agent postinstall"
  exit 1
}

grep -q 'build_hermes_core.sh' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not build the offline Hermes Core"
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
  '"$hermes_dir/runtime"' \
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

grep -q 'install_vendored_pi_extensions' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not install the reviewed pi-plan-mode vendor"
  exit 1
}
grep -q '/tmp/agent-runtime-pi-plan-mode.ts' "$FETCH_SCRIPT" || {
  echo "fetch_node_runtime.sh does not register the vendored pi-plan-mode extension"
  exit 1
}

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
  echo "20-node-agent.sh does not resolve the active runtime generation compatibility link"
  exit 1
}

grep -q 'agent-runtime upgrade' "$PROFILE_UPDATE" || {
  echo "30-agent-update-check.sh does not advertise signed generation upgrades"
  exit 1
}
if grep -q 'npm i -g --prefix /data/node\|hermes update' "$PROFILE_UPDATE"; then
  echo "30-agent-update-check.sh still advertises in-place mutation of an immutable generation"
  exit 1
fi

if grep -q '/opt/node/bin/opencode --version' "$PROFILE_UPDATE"; then
  echo "30-agent-update-check.sh reports the baked version instead of the PATH-resolved one"
  exit 1
fi

# Regression: a musl cross install leaves three classes of native the router can
# never load: node-pre-gyp packages (msgpackr-extract) ship the build host's
# prebuild inside their main tarball so no optional platform package exists for
# npm to skip; npm filters optional packages by os/cpu only, so every glibc twin
# of a musl build is installed too; and pi-tui / pnpm's bundled @reflink pack
# whole-platform prebuild directories into their own tarball. An unpruned
# x86-64 module aborted every arm64 firmware build.
PRUNE_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$PRUNE_FIXTURE"' EXIT
make_elf_stub() {
  local path="$1" machine="$2"
  mkdir -p "$(dirname "$path")"
  {
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\003\000'
    printf "\\$(printf '%03o' $((machine & 255)))\\$(printf '%03o' $((machine >> 8)))"
    head -c 9000 /dev/zero
  } >"$path"
}
make_macho_stub() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  { printf '\317\372\355\376'; head -c 9000 /dev/zero; } >"$path"
}
make_pe_stub() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  { printf 'MZ\220\000'; head -c 9000 /dev/zero; } >"$path"
}
make_elf_stub "$PRUNE_FIXTURE/msgpackr-extract/build/Release/extract.node" 62
make_elf_stub "$PRUNE_FIXTURE/koffi/build/koffi/musl_arm64/koffi.node" 183
make_elf_stub "$PRUNE_FIXTURE/koffi/build/koffi/linux_arm64/koffi.node" 183
make_elf_stub "$PRUNE_FIXTURE/@opentui/core-linux-arm64/libopentui.so" 183
make_elf_stub "$PRUNE_FIXTURE/@opentui/core-linux-arm64-musl/libopentui.so" 183
make_elf_stub "$PRUNE_FIXTURE/@mariozechner/clipboard-linux-arm64-gnu/clipboard.linux-arm64-gnu.node" 183
make_elf_stub "$PRUNE_FIXTURE/@mariozechner/clipboard-linux-arm64-musl/clipboard.linux-arm64-musl.node" 183
make_macho_stub "$PRUNE_FIXTURE/@reflink/reflink-darwin-arm64/reflink.darwin-arm64.node"
make_pe_stub "$PRUNE_FIXTURE/@reflink/reflink-win32-x64-msvc/reflink.win32-x64-msvc.node"
# Negative control for the magic whitelist: a .node that is not a binary at all
# must survive, because "not ELF" alone would also match text files.
mkdir -p "$PRUNE_FIXTURE/text-pkg"
printf 'module.exports = {}\n' >"$PRUNE_FIXTURE/text-pkg/shim.node"
cp "$ROOT_DIR/Scripts/retry.sh" "$PRUNE_FIXTURE/"
sed '$d' "$FETCH_SCRIPT" >"$PRUNE_FIXTURE/lib.sh"
(
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$PRUNE_FIXTURE/lib.sh"
  NODE_LIB_DIR="$PRUNE_FIXTURE"
  prune_foreign_platform_builds arm64 >/dev/null
) || { echo "prune_foreign_platform_builds arm64 failed on the fixture"; exit 1; }
for pruned in \
  'msgpackr-extract/build/Release/extract.node' \
  'koffi/build/koffi/linux_arm64/koffi.node' \
  '@opentui/core-linux-arm64/libopentui.so' \
  '@mariozechner/clipboard-linux-arm64-gnu/clipboard.linux-arm64-gnu.node' \
  '@reflink/reflink-darwin-arm64/reflink.darwin-arm64.node' \
  '@reflink/reflink-win32-x64-msvc/reflink.win32-x64-msvc.node'; do
  if [ -e "$PRUNE_FIXTURE/$pruned" ]; then
    echo "prune_foreign_platform_builds kept an unloadable native: $pruned"
    exit 1
  fi
done
for needed in \
  'koffi/build/koffi/musl_arm64/koffi.node' \
  '@opentui/core-linux-arm64-musl/libopentui.so' \
  '@mariozechner/clipboard-linux-arm64-musl/clipboard.linux-arm64-musl.node' \
  'text-pkg/shim.node'; do
  if [ ! -e "$PRUNE_FIXTURE/$needed" ]; then
    echo "prune_foreign_platform_builds deleted something the device needs: $needed"
    exit 1
  fi
done

echo "node runtime and agent preload guard test passed"
