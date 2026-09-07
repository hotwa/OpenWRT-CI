#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_JSON="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
AGENT_RUNTIME="$ROOT_DIR/files/usr/sbin/agent-runtime"

fail() { echo "pi-agent-modes: $*" >&2; exit 1; }

for path in "$PACKAGE_JSON" "$FETCH_SCRIPT" "$AGENT_RUNTIME"; do
  [ -f "$path" ] || fail "missing $path"
done

# pi-agent-modes must be a runtime dependency resolved at build time.
node - "$PACKAGE_JSON" <<'NODE' || fail "package.json dependencies must include pi-agent-modes"
const manifest = require(process.argv[2]);
if (!('pi-agent-modes' in (manifest.dependencies || {}))) process.exit(1);
NODE

# pi-agent-modes must be registered as an OpenWrt Pi extension so the
# firmware bundler and verifier treat it as a first-class extension.
node - "$PACKAGE_JSON" <<'NODE' || fail "package.json openwrtPiExtensions must include pi-agent-modes"
const manifest = require(process.argv[2]);
if (!Array.isArray(manifest.openwrtPiExtensions) ||
    !manifest.openwrtPiExtensions.includes('pi-agent-modes')) process.exit(1);
NODE

# The staged settings.json template must install pi-agent-modes so the
# headless Multica agent loads the yolo mode without interactive approval.
grep -Fq '"npm:pi-agent-modes"' "$FETCH_SCRIPT" ||
  fail "fetch_node_runtime.sh settings template must include npm:pi-agent-modes"

# The retired plan-mode vendored extension link must not be staged.
if grep -Fq '/tmp/agent-runtime-pi-plan-mode.ts' "$FETCH_SCRIPT"; then
  fail "fetch_node_runtime.sh still references the retired pi-plan-mode extension"
fi

# The retired extension-link publisher must not remain in the runtime manager.
if grep -Fq 'publish_pi_extension_link' "$AGENT_RUNTIME"; then
  fail "agent-runtime still defines the retired publish_pi_extension_link helper"
fi

echo "pi-agent-modes integration tests passed"
