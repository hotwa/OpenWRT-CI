#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_SCRIPT="$ROOT_DIR/Scripts/CommandCodeProviderConfig.sh"
AUTO_MOUNT="$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
CORE_WF="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
WLG_WF="$ROOT_DIR/.github/workflows/WLG-RE-CS-07-BUILD.yml"
PI_SETTINGS="$ROOT_DIR/files/etc/pi/agent/settings.json"
PI_MODELS="$ROOT_DIR/files/etc/pi/agent/models.json"

[ -f "$CONFIG_SCRIPT" ] || { echo "missing CommandCodeProviderConfig.sh"; exit 1; }
# WRT-CORE.yml executes the script directly (not via bash), so it must carry
# the executable bit in git.  A 100644 entry would Permission-deny on runners.
[ "$(git ls-files --stage -- "$CONFIG_SCRIPT" | awk '{print $1}')" = "100755" ] || {
	echo "CommandCodeProviderConfig.sh is not marked executable (git mode 100755 required)"
	exit 1
}
[ -f "$AUTO_MOUNT" ] || { echo "missing 99-auto-mount-data"; exit 1; }
[ -f "$CORE_WF" ] || { echo "missing WRT-CORE.yml"; exit 1; }
[ -f "$PI_SETTINGS" ] || { echo "missing pi settings.json"; exit 1; }
[ -f "$PI_MODELS" ] || { echo "missing pi models.json"; exit 1; }

bash -n "$CONFIG_SCRIPT"
sh -n "$AUTO_MOUNT"

# Static guards: the workflow must declare and pass the secret, and the
# first-boot migrator must carry auth.json onto /data for both Pi and CommandCode CLI.
grep -Fq 'COMMANDCODE_API_KEY' "$CORE_WF"
grep -Fq 'CommandCodeProviderConfig.sh' "$CORE_WF"
grep -Fq 'COMMANDCODE_API_KEY' "$WLG_WF"
grep -Fq 'auth.json' "$AUTO_MOUNT"
grep -Fq 'commandcode/auth.json' "$AUTO_MOUNT"

# The build-time settings template (fetch_node_runtime.sh) must register
# pi-commandcode-provider with the npm: prefix so Pi 0.85+ auto-loads it
# without an explicit --extension flag.  Bare package names are unreliable.
FETCH_RUNTIME="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
[ -f "$FETCH_RUNTIME" ] || { echo "missing fetch_node_runtime.sh"; exit 1; }
grep -Fq '"npm:pi-commandcode-provider"' "$FETCH_RUNTIME" || {
	echo "fetch_node_runtime.sh must use npm:pi-commandcode-provider (not bare package name)"
	exit 1
}
# The first-boot migrator must create the npm symlink so Pi resolves the
# npm: package reference against /data/pi/agent/npm/node_modules.
grep -Fq 'ensure_commandcode_npm_link' "$AUTO_MOUNT" || {
	echo "99-auto-mount-data must create the pi-commandcode-provider npm symlink"
	exit 1
}

# The repository's static settings must keep the public default; the secret
# injection step is what flips it to commandcode at build time.
grep -Fq '"defaultProvider"' "$PI_SETTINGS"
grep -Fq 'pi-commandcode-provider' "$PI_MODELS" || true

CASE_ROOT="$(mktemp -d)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$CASE_ROOT" "$TMP_ROOT"' EXIT
mkdir -p "$CASE_ROOT/etc/pi/agent" "$CASE_ROOT/root/.pi/agent"

write_settings() {
  local dir="$1"
  cat >"$dir/settings.json" <<'EOF'
{
  "defaultProvider": "office-sglang",
  "defaultModel": "Qwen3.8-27B",
  "defaultThinkingLevel": "medium",
  "enableInstallTelemetry": false,
  "defaultProjectTrust": "ask",
  "packages": ["npm:pi-commandcode-provider", "pi-package-manager"],
  "autoUpdate": false
}
EOF
}

write_settings "$CASE_ROOT/etc/pi/agent"
write_settings "$CASE_ROOT/root/.pi/agent"

# Test 1: empty secret leaves the firmware untouched.
COMMANDCODE_API_KEY="" bash "$CONFIG_SCRIPT" "$CASE_ROOT"
[ "$(jq -r .defaultProvider "$CASE_ROOT/etc/pi/agent/settings.json")" = "office-sglang" ]
[ ! -f "$CASE_ROOT/etc/pi/agent/auth.json" ]

# Test 2: valid secret writes auth.json and flips defaultProvider.
# Force the fallback cache by pointing at an unreachable URL (connection
# refused on 127.0.0.1:1 is immediate).  The real API is publicly reachable
# and would return a non-deterministic model order.
COMMANDCODE_API_KEY="user_abc123def456" \
  COMMANDCODE_MODELS_URL="http://127.0.0.1:1/models" \
  bash "$CONFIG_SCRIPT" "$CASE_ROOT"

for dir in "$CASE_ROOT/etc/pi/agent" "$CASE_ROOT/root/.pi/agent"; do
  [ -f "$dir/auth.json" ] || { echo "missing auth.json in $dir"; exit 1; }
  [ "$(jq -r .apiKey "$dir/auth.json")" = "user_abc123def456" ]
  [ "$(stat -c '%a' "$dir/auth.json")" = "600" ]
  [ "$(jq -r .defaultProvider "$dir/settings.json")" = "commandcode" ]
  [ "$(jq -r .defaultModel "$dir/settings.json")" = "Qwen/Qwen3.8-Flash" ]
  # packages list must survive the jq edit; npm: prefix ensures Pi loads it.
  [ "$(jq -r '.packages[0]' "$dir/settings.json")" = "npm:pi-commandcode-provider" ]
done

# CommandCode CLI auth.json must also be written so cmd / cmdc works zero-config.
[ -f "$CASE_ROOT/etc/commandcode/auth.json" ] || { echo "missing /etc/commandcode/auth.json"; exit 1; }
[ "$(jq -r .apiKey "$CASE_ROOT/etc/commandcode/auth.json")" = "user_abc123def456" ]
[ "$(stat -c '%a' "$CASE_ROOT/etc/commandcode/auth.json")" = "600" ]

# Test 3: malformed key prefix is rejected.
if COMMANDCODE_API_KEY="sk-bad-prefix" bash "$CONFIG_SCRIPT" "$CASE_ROOT" 2>/dev/null; then
  echo "FAIL: malformed key prefix was accepted"
  exit 1
fi

# Test 4: auth.json is idempotent — running twice does not corrupt JSON.
COMMANDCODE_API_KEY="user_second_run" \
  COMMANDCODE_MODELS_URL="http://127.0.0.1:1/models" \
  bash "$CONFIG_SCRIPT" "$CASE_ROOT"
jq -e . "$CASE_ROOT/etc/pi/agent/auth.json" >/dev/null
[ "$(jq -r .apiKey "$CASE_ROOT/etc/pi/agent/auth.json")" = "user_second_run" ]

# Test 5: pre-built model cache is generated in /etc/pi/agent/.
[ -f "$CASE_ROOT/etc/pi/agent/commandcode-models.json" ] || {
  echo "FAIL: commandcode-models.json cache was not generated"
  exit 1
}
jq -e '.data | type == "array"' "$CASE_ROOT/etc/pi/agent/commandcode-models.json" >/dev/null || {
  echo "FAIL: commandcode-models.json is not valid JSON with a data array"
  exit 1
}
# The fallback cache must contain at least one open-source model.
[ "$(jq -r '.data[0].id' "$CASE_ROOT/etc/pi/agent/commandcode-models.json")" = "Qwen/Qwen3.8-Flash" ] || {
  echo "FAIL: fallback cache does not start with Qwen/Qwen3.8-Flash"
  exit 1
}

# Test 6: defaultModel is dynamically selected from the cache, not hardcoded.
# With the fallback cache (API unreachable in tests), the first open-source
# model is Qwen/Qwen3.8-Flash.
[ "$(jq -r .defaultModel "$CASE_ROOT/etc/pi/agent/settings.json")" = "Qwen/Qwen3.8-Flash" ]

# Test 7: custom cache input (COMMANDCODE_MODEL_CACHE_INPUT) overrides the API
# fetch and drives model selection.  With a deepseek flash model present, it
# must be selected as the highest-priority preferred model.
CUSTOM_CACHE="$(mktemp)"
cat >"$CUSTOM_CACHE" <<'EOF'
{"object":"list","data":[{"id":"anthropic/claude-3.5-sonnet","object":"model","owned_by":"anthropic"},{"id":"deepseek/deepseek-v4-flash","object":"model","owned_by":"deepseek"},{"id":"Qwen/Qwen3.8-27B","object":"model","owned_by":"qwen"}]}
EOF
CASE_CUSTOM="$TMP_ROOT/custom-cache"
mkdir -p "$CASE_CUSTOM/etc/pi/agent" "$CASE_CUSTOM/root/.pi/agent"
write_settings "$CASE_CUSTOM/etc/pi/agent"
write_settings "$CASE_CUSTOM/root/.pi/agent"
COMMANDCODE_API_KEY="user_custom_cache" \
  COMMANDCODE_MODEL_CACHE_INPUT="$CUSTOM_CACHE" \
  bash "$CONFIG_SCRIPT" "$CASE_CUSTOM"
[ "$(jq -r .defaultModel "$CASE_CUSTOM/etc/pi/agent/settings.json")" = "deepseek/deepseek-v4-flash" ] || {
  echo "FAIL: defaultModel was not selected from custom cache (expected deepseek/deepseek-v4-flash)"
  exit 1
}
# The cache file must match the custom input (copied, not fetched).
cmp -s "$CUSTOM_CACHE" "$CASE_CUSTOM/etc/pi/agent/commandcode-models.json" || {
  echo "FAIL: commandcode-models.json does not match custom cache input"
  exit 1
}
rm -f "$CUSTOM_CACHE"

# Test 8: cache with no flash models falls back to the first "pro" model.
PRO_CACHE="$(mktemp)"
cat >"$PRO_CACHE" <<'EOF'
{"object":"list","data":[{"id":"anthropic/claude-3.5-sonnet","object":"model"},{"id":"deepseek/deepseek-v4-pro","object":"model"},{"id":"Qwen/Qwen3.8-27B","object":"model"}]}
EOF
CASE_PRO="$TMP_ROOT/pro-cache"
mkdir -p "$CASE_PRO/etc/pi/agent" "$CASE_PRO/root/.pi/agent"
write_settings "$CASE_PRO/etc/pi/agent"
write_settings "$CASE_PRO/root/.pi/agent"
COMMANDCODE_API_KEY="user_pro_cache" \
  COMMANDCODE_MODEL_CACHE_INPUT="$PRO_CACHE" \
  bash "$CONFIG_SCRIPT" "$CASE_PRO"
[ "$(jq -r .defaultModel "$CASE_PRO/etc/pi/agent/settings.json")" = "deepseek/deepseek-v4-pro" ] || {
  echo "FAIL: no-flash fallback did not select first pro model"
  exit 1
}
rm -f "$PRO_CACHE"

# Test 9: cache with neither flash nor pro models must cause the build to fail
# (no built-in fallback — a catalog without flash/pro indicates an API problem).
NOMATCH_CACHE="$(mktemp)"
cat >"$NOMATCH_CACHE" <<'EOF'
{"object":"list","data":[{"id":"anthropic/claude-3.5-sonnet","object":"model"},{"id":"openai/gpt-4o","object":"model"}]}
EOF
CASE_NOMATCH="$TMP_ROOT/nomatch-cache"
mkdir -p "$CASE_NOMATCH/etc/pi/agent" "$CASE_NOMATCH/root/.pi/agent"
write_settings "$CASE_NOMATCH/etc/pi/agent"
write_settings "$CASE_NOMATCH/root/.pi/agent"
if COMMANDCODE_API_KEY="user_nomatch_cache" \
  COMMANDCODE_MODEL_CACHE_INPUT="$NOMATCH_CACHE" \
  bash "$CONFIG_SCRIPT" "$CASE_NOMATCH" 2>/dev/null; then
  echo "FAIL: script succeeded with a cache containing neither flash nor pro models"
  exit 1
fi
rm -f "$NOMATCH_CACHE"

# Test 9: cache file must not contain the API key (only model directory).
if grep -Fq 'user_' "$CASE_ROOT/etc/pi/agent/commandcode-models.json"; then
  echo "FAIL: commandcode-models.json contains API key material"
  exit 1
fi

echo "commandcode provider config tests passed"
