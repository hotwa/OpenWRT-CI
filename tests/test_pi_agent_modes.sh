#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_JSON="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
PI_SETTINGS="$ROOT_DIR/files/etc/pi/agent/settings.json"
PI_MODES_CONFIG="$ROOT_DIR/files/etc/pi/agent/modes.config.json"
AGENT_RUNTIME="$ROOT_DIR/files/usr/sbin/agent-runtime"

fail() { echo "pi-agent-modes: $*" >&2; exit 1; }

for path in "$PACKAGE_JSON" "$FETCH_SCRIPT" "$PI_SETTINGS" "$PI_MODES_CONFIG" "$AGENT_RUNTIME"; do
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
grep -Fq 'PI_SETTINGS_TEMPLATE="$ROOT_DIR/files/etc/pi/agent/settings.json"' "$FETCH_SCRIPT" ||
  fail "fetch_node_runtime.sh must declare the canonical Pi settings template"
grep -Fq 'install -Dm0644 "$PI_SETTINGS_TEMPLATE" "$TARGET_FILES/etc/pi/agent/settings.json"' "$FETCH_SCRIPT" ||
  fail "fetch_node_runtime.sh must install the canonical Pi settings template"
grep -Fq '"npm:pi-agent-modes"' "$PI_SETTINGS" ||
  fail "canonical Pi settings template must include npm:pi-agent-modes"

node - "$PI_MODES_CONFIG" <<'NODE' || fail "Pi modes config must be valid JSON with defaultMode=yolo"
const config = JSON.parse(require('node:fs').readFileSync(process.argv[2], 'utf8'));
if (config.defaultMode !== 'yolo') process.exit(1);
NODE
grep -Fq 'PI_MODES_CONFIG_TEMPLATE="$ROOT_DIR/files/etc/pi/agent/modes.config.json"' "$FETCH_SCRIPT" ||
  fail "fetch_node_runtime.sh must declare the canonical Pi modes config template"
grep -Fq 'install -Dm0644 "$PI_MODES_CONFIG_TEMPLATE" "$TARGET_FILES/etc/pi/agent/modes.config.json"' "$FETCH_SCRIPT" ||
  fail "fetch_node_runtime.sh must install the default modes config into the firmware"
grep -Fq 'cp -f "$PI_MODES_CONFIG_TEMPLATE" "$PI_CONFIG_DIR/modes.config.json"' "$FETCH_SCRIPT" ||
  fail "fetch_node_runtime.sh must stage the default modes config for /root/.pi"
grep -Fq 'lazy-extensions.json modes.config.json' "$ROOT_DIR/files/etc/init.d/agent-data-prep" ||
  fail "agent-data-prep must seed the modes config on persistent /data only when absent"

# The retired plan-mode vendored extension link must not be staged.
if grep -Fq '/tmp/agent-runtime-pi-plan-mode.ts' "$FETCH_SCRIPT"; then
  fail "fetch_node_runtime.sh still references the retired pi-plan-mode extension"
fi

# The retired extension-link publisher must not remain in the runtime manager.
if grep -Fq 'publish_pi_extension_link' "$AGENT_RUNTIME"; then
  fail "agent-runtime still defines the retired publish_pi_extension_link helper"
fi

echo "pi-agent-modes integration tests passed"
