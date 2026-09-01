#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
UV_FETCH="$ROOT_DIR/Scripts/fetch_uv_runtime.sh"
MANIFEST="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
LOCKFILE="$ROOT_DIR/Scripts/node-agent-runtime/package-lock.json"
MODELS="$ROOT_DIR/files/etc/pi/agent/models.json"
SETTINGS="$ROOT_DIR/files/etc/pi/agent/settings.json"
PROFILE_NODE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
PROFILE_UPDATE="$ROOT_DIR/files/etc/profile.d/30-agent-update-check.sh"

fail() { echo "node runtime guard: $*" >&2; exit 1; }
for path in "$WORKFLOW" "$FETCH_SCRIPT" "$UV_FETCH" "$MANIFEST" "$LOCKFILE" "$MODELS" "$SETTINGS" "$PROFILE_NODE" "$PROFILE_UPDATE"; do
  [ -f "$path" ] || fail "missing $path"
done
bash -n "$FETCH_SCRIPT"
bash -n "$UV_FETCH"

grep -Fq '$GITHUB_WORKSPACE/Scripts/fetch_node_runtime.sh' "$WORKFLOW" || fail "WRT-CORE does not build the Node runtime"
grep -Fq '$GITHUB_WORKSPACE/Scripts/fetch_multica_runtime.sh' "$WORKFLOW" || fail "WRT-CORE does not build Multica"
grep -Fq '$GITHUB_WORKSPACE/Scripts/fetch_uv_runtime.sh' "$WORKFLOW" || fail "WRT-CORE does not stage the pinned uv runtime"
grep -Fq 'PYTHON_SERIES="3.13"' "$UV_FETCH" || fail "uv runtime must carry exactly Python 3.13"
grep -Fq 'UV_OFFLINE=1' "$ROOT_DIR/files/usr/sbin/uv-runtime-provision" || fail "Python provisioning must remain offline"

for term in 'linux-arm64-musl' 'linux-x64-musl' 'npm ci' '--ignore-scripts' \
  'prune_foreign_platform_builds' 'verify_agent_runtime_arch' \
  'install_vendored_pi_extensions' 'install_pi_search_tools' \
  'PI_MODEL_CATALOG="$ROOT_DIR/files/etc/pi/agent/models.json"' \
  'install -Dm0644 "$PI_MODEL_CATALOG" "$TARGET_FILES/etc/pi/agent/models.json"' \
  'cmdc' 'command-code' 'commandcode'; do
  grep -Fq -- "$term" "$FETCH_SCRIPT" || fail "fetch_node_runtime.sh omits $term"
done
# The bump helper re-resolves the lock with --legacy-peer-deps; the firmware
# cross-install must use the same flag or npm 11 strict peer resolution rejects
# the resulting lock with EUSAGE ("Missing ... from lock file").
grep -Fq -- '--legacy-peer-deps' "$FETCH_SCRIPT" || fail "fetch_node_runtime.sh must install with --legacy-peer-deps"
# configure_pi_extensions must register every preinstalled package in Pi's
# settings so pi actually loads them (not just installs them under /opt/node).
grep -Fq '"pi-commandcode-provider"' "$FETCH_SCRIPT" || fail "fetch_node_runtime.sh does not register pi-commandcode-provider in settings"

if grep -Fq 'CONFIG_PACKAGE_ripgrep=y' "$ROOT_DIR/Config/GENERAL.txt"; then
  fail "feed ripgrep would pull Rust into every firmware build"
fi
for term in 'PI_FD_VERSION="10.5.0"' 'PI_RIPGREP_VERSION="15.2.0"' \
  'fd-v${PI_FD_VERSION}-aarch64-unknown-linux-musl.tar.gz' \
  'ripgrep-${PI_RIPGREP_VERSION}-aarch64-unknown-linux-musl.tar.gz' \
  'install_verified_pi_search_binary' 'static-pie linked'; do
  grep -Fq "$term" "$FETCH_SCRIPT" || fail "Pi fd verification is incomplete: $term"
done

for pkg in 'command-code' '@earendil-works/pi-coding-agent' '@aaronkyriesenbach/pi-package-manager' 'btw-pi' 'pi-web-search' 'pi-wechat-assistant' 'pi-commandcode-provider' 'pnpm'; do
  grep -Fq "$pkg" "$MANIFEST" || fail "package manifest omits $pkg"
done
for retired in 'opencode-ai' 'hermes-agent' '@tarquinen/opencode-dcp' '@mohak34/opencode-notifier' 'opencode-conductor-plugin'; do
  if grep -Fq "$retired" "$MANIFEST" || grep -Fq "node_modules/$retired" "$LOCKFILE"; then
    fail "retired runtime package remains: $retired"
  fi
done

MODELS="$MODELS" SETTINGS="$SETTINGS" node <<'NODE'
const fs = require('node:fs');
const models = JSON.parse(fs.readFileSync(process.env.MODELS, 'utf8'));
const settings = JSON.parse(fs.readFileSync(process.env.SETTINGS, 'utf8'));
const provider = models.providers?.['office-sglang'];
if (!provider || provider.baseUrl !== 'http://192.168.11.159:8001/v1' || provider.api !== 'openai-completions') process.exit(1);
if (!provider.models?.some(m => m.id === 'Qwen3.8-27B')) process.exit(2);
if (settings.defaultProvider !== 'office-sglang' || settings.defaultModel !== 'Qwen3.8-27B') process.exit(3);
const declaredModels = Object.values(models.providers ?? {}).flatMap(provider => provider.models ?? []);
if (!declaredModels.length) process.exit(4);
for (const m of declaredModels) {
  if (m.id === 'automodel' && m.contextWindow === 128000) continue;
  if (m.contextWindow !== 262144) process.exit(4);
}
const fallback = models.providers?.cloudcollector;
if (!fallback || fallback.baseUrl !== 'https://fhk.org/v1' || fallback.api !== 'openai-completions') process.exit(5);
if (fallback.apiKey !== '!cat /data/pi/agent/secrets/cloudcollector-api-key') process.exit(6);
if (!fallback.models?.some(m => m.id === 'automodel' && m.contextWindow === 262144)) process.exit(7);
const vllm = models.providers?.['vllm-qwen38'];
if (!vllm || vllm.baseUrl !== 'http://x9700x.hs.jmsu.top:8000/v1' || vllm.api !== 'openai-completions') process.exit(8);
if (vllm.apiKey !== 'not-needed') process.exit(9);
if (!vllm.models?.some(m => m.id === 'automodel' && m.contextWindow === 128000 && m.reasoning === true)) process.exit(10);
NODE

grep -Fq '/data/node/bin' "$PROFILE_NODE" || fail "login PATH does not prefer an active generation"
grep -Fq 'cmdc --version' "$PROFILE_UPDATE" || fail "login banner does not show CommandCode"
if grep -Eqi 'opencode|hermes' "$PROFILE_NODE" "$PROFILE_UPDATE"; then
  fail "login profile still references a retired runtime"
fi

echo "node runtime and agent preload guard test passed"
