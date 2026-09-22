#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
UV_FETCH="$ROOT_DIR/Scripts/fetch_uv_runtime.sh"
MANIFEST="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
PEER_RESOLVER="$ROOT_DIR/Scripts/ensure_pi_extension_peers.js"
EXTENSION_VERIFIER="$ROOT_DIR/Scripts/verify_pi_extensions.js"
CONFLICT_VERIFIER="$ROOT_DIR/Scripts/verify_pi_extension_conflicts.js"
MODELS="$ROOT_DIR/files/etc/pi/agent/models.json"
SETTINGS="$ROOT_DIR/files/etc/pi/agent/settings.json"
LAZY_EXTENSIONS="$ROOT_DIR/files/etc/pi/agent/lazy-extensions.json"
PROFILE_NODE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
PROFILE_UPDATE="$ROOT_DIR/files/etc/profile.d/30-agent-update-check.sh"

fail() { echo "node runtime guard: $*" >&2; exit 1; }
for path in "$WORKFLOW" "$FETCH_SCRIPT" "$UV_FETCH" "$MANIFEST" "$PEER_RESOLVER" "$EXTENSION_VERIFIER" "$CONFLICT_VERIFIER" "$MODELS" "$SETTINGS" "$LAZY_EXTENSIONS" "$PROFILE_NODE" "$PROFILE_UPDATE"; do
  [ -f "$path" ] || fail "missing $path"
done
bash -n "$FETCH_SCRIPT"
bash -n "$UV_FETCH"
node --check "$PEER_RESOLVER"
node --check "$EXTENSION_VERIFIER"
node --check "$CONFLICT_VERIFIER"
[ ! -e "$ROOT_DIR/Scripts/node-agent-runtime/package-lock.json" ] ||
  fail "source catalog lockfile would freeze latest-at-build plugin resolution"

grep -Fq '$GITHUB_WORKSPACE/Scripts/fetch_node_runtime.sh' "$WORKFLOW" || fail "WRT-CORE does not build the Node runtime"
grep -Fq '$GITHUB_WORKSPACE/Scripts/fetch_multica_runtime.sh' "$WORKFLOW" || fail "WRT-CORE does not build Multica"
grep -Fq '$GITHUB_WORKSPACE/Scripts/fetch_uv_runtime.sh' "$WORKFLOW" || fail "WRT-CORE does not stage the pinned uv runtime"
grep -Fq 'PYTHON_SERIES="3.13"' "$UV_FETCH" || fail "uv runtime must carry exactly Python 3.13"
grep -Fq 'UV_OFFLINE=1' "$ROOT_DIR/files/usr/sbin/uv-runtime-provision" || fail "Python provisioning must remain offline"

for term in 'linux-arm64-musl' 'linux-x64-musl' \
  'prune_foreign_platform_builds' 'verify_agent_runtime_arch' \
  'install_pi_search_tools' \
  'PI_MODEL_CATALOG="$ROOT_DIR/files/etc/pi/agent/models.json"' \
  'PI_SETTINGS_TEMPLATE="$ROOT_DIR/files/etc/pi/agent/settings.json"' \
  'PI_LAZY_EXTENSIONS_TEMPLATE="$ROOT_DIR/files/etc/pi/agent/lazy-extensions.json"' \
  'install -Dm0644 "$PI_MODEL_CATALOG" "$TARGET_FILES/etc/pi/agent/models.json"' \
  'install -Dm0644 "$PI_SETTINGS_TEMPLATE" "$TARGET_FILES/etc/pi/agent/settings.json"' \
  'install -Dm0644 "$PI_LAZY_EXTENSIONS_TEMPLATE" "$TARGET_FILES/etc/pi/agent/lazy-extensions.json"' \
  'cmdc' 'command-code' 'commandcode'; do
  grep -Fq -- "$term" "$FETCH_SCRIPT" || fail "fetch_node_runtime.sh omits $term"
done
grep -Fq -- 'ensure_pi_extension_peers.js' "$FETCH_SCRIPT" || fail "fetch_node_runtime.sh does not align Pi peers"
grep -Fq -- 'verify_pi_extensions.js' "$FETCH_SCRIPT" || fail "fetch_node_runtime.sh does not load-check Pi extensions"
grep -Fq -- 'verify_pi_extension_conflicts.js' "$FETCH_SCRIPT" || fail "fetch_node_runtime.sh does not run Pi native conflict checks"
for term in '--ignore-scripts' '--legacy-peer-deps' 'PI EXTENSION DEPENDENCY TREE OK' 'PI EXTENSIONS OK'; do
  grep -Fq -- "$term" "$PEER_RESOLVER" "$EXTENSION_VERIFIER" || fail "Pi extension build gate omits $term"
done
# configure_pi_extensions must register every preinstalled package in Pi's
# settings so pi actually loads them (not just installs them under /opt/node).
# Match both "pi-commandcode-provider" (legacy) and "npm:pi-commandcode-provider" (current).
grep -Fq 'pi-commandcode-provider' "$SETTINGS" || fail "default settings do not register pi-commandcode-provider"

if grep -Fq 'CONFIG_PACKAGE_ripgrep=y' "$ROOT_DIR/Config/GENERAL.txt"; then
  fail "feed ripgrep would pull Rust into every firmware build"
fi
for term in 'PI_FD_VERSION="10.5.0"' 'PI_RIPGREP_VERSION="15.2.0"' \
  'fd-v${PI_FD_VERSION}-aarch64-unknown-linux-musl.tar.gz' \
  'ripgrep-${PI_RIPGREP_VERSION}-aarch64-unknown-linux-musl.tar.gz' \
  'install_verified_pi_search_binary' 'static-pie linked'; do
  grep -Fq "$term" "$FETCH_SCRIPT" || fail "Pi fd verification is incomplete: $term"
done

for pkg in 'command-code' '@earendil-works/pi-coding-agent' 'pi-package-manager' 'btw-pi' 'pi-web-search' 'pi-undo-redo' 'pi-wechat-assistant' '@router-for-me/pi-cliproxyapi-provider' 'pi-commandcode-provider' 'pi-lazy-extensions' 'pi-mcp-adapter' 'pi-tool-search' 'pi-web-access' 'pi-lsp' 'pi-cost' 'pi-cache-graph' 'pi-inspect' 'pi-subagents' '@capdiem/pi-todo' '@zephyrdeng/pi-review' '@luxusai/pi-hindsight' 'pi-interactive-shell' '@narumitw/pi-statusline' 'pnpm'; do
  grep -Fq "$pkg" "$MANIFEST" || fail "package manifest omits $pkg"
done
node - "$MANIFEST" "$SETTINGS" "$LAZY_EXTENSIONS" <<'NODE' || fail "Pi extension catalog/settings contract is invalid"
const fs = require('node:fs');
const [manifestPath, settingsPath, lazyExtensionsPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
const lazyExtensions = JSON.parse(fs.readFileSync(lazyExtensionsPath, 'utf8'));
for (const [name, selector] of Object.entries(manifest.dependencies || {})) {
  if (selector !== 'latest') process.exit(1);
}
if (!Array.isArray(manifest.openwrtPiExtensions) || manifest.openwrtPiExtensions.length === 0) process.exit(2);
if (!Array.isArray(settings.packages)) process.exit(3);
const configured = new Set(settings.packages.map(spec => spec.replace(/^npm:/, '')));
for (const extension of manifest.openwrtPiExtensions) {
  if (!configured.has(extension)) process.exit(4);
}
if (!Array.isArray(manifest.openwrtPiLazyExtensions) || manifest.openwrtPiLazyExtensions.length === 0) process.exit(5);
for (const extension of manifest.openwrtPiLazyExtensions) {
  if (!Object.prototype.hasOwnProperty.call(manifest.dependencies, extension)) process.exit(6);
  if (configured.has(extension)) process.exit(7);
}
const webAccess = lazyExtensions.extensions?.find(extension => extension?.name === 'web-access');
if (!webAccess || webAccess.path !== '/data/node/lib/node_modules/pi-web-access/index.ts' || webAccess.lifecycle !== 'lazy') process.exit(8);
if (!Array.isArray(webAccess.toolSummary) || !webAccess.toolSummary.includes('web_search')) process.exit(9);
if (!settings.toolSearch || settings.toolSearch.showToolSearchFooterStatus !== false) process.exit(10);
NODE
if grep -Fq '@aaronkyriesenbach/pi-package-manager' "$MANIFEST"; then
  fail "the legacy scoped package manager must not be preloaded alongside pi-package-manager"
fi
if grep -Fq '@monotykamary/pi-tps' "$MANIFEST"; then
  fail "standalone pi-tps must not duplicate the TPS extension bundled with pi-cliproxyapi-provider"
fi
for forbidden in 'pi-mcp-extension' 'pi-code' '@narumitw/pi-subagents' '@henryqw/pi-subagent'; do
  if grep -Fq "$forbidden" "$MANIFEST"; then
    fail "excluded Pi extension remains preloaded: $forbidden"
  fi
done
for retired in 'opencode-ai' 'hermes-agent' '@tarquinen/opencode-dcp' '@mohak34/opencode-notifier' 'opencode-conductor-plugin'; do
  if grep -Fq "$retired" "$MANIFEST"; then
    fail "retired runtime package remains: $retired"
  fi
done

MODELS="$MODELS" SETTINGS="$SETTINGS" node <<'NODE'
const fs = require('node:fs');
const models = JSON.parse(fs.readFileSync(process.env.MODELS, 'utf8'));
const settings = JSON.parse(fs.readFileSync(process.env.SETTINGS, 'utf8'));
const provider = models.providers?.['office-sglang'];
if (!provider || provider.baseUrl !== 'http://192.168.11.159:8101/v1' || provider.api !== 'openai-completions' || provider.apiKey !== 'sk-local') process.exit(1);
const localModel = provider.models?.find(m => m.id === 'Qwen3.8-Flash-Next');
if (!localModel || localModel.contextWindow !== 262144 || localModel.maxTokens !== 32768 || !localModel.reasoning) process.exit(2);
if (provider.compat?.supportsReasoningEffort !== true || localModel.thinkingLevelMap?.high !== 'xhigh') process.exit(12);
if (settings.defaultProvider !== 'commandcode' || settings.defaultModel !== 'deepseek/deepseek-v4.1-flash') process.exit(3);
if (settings.defaultThinkingLevel !== 'medium') process.exit(11);
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
