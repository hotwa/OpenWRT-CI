#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="$ROOT_DIR/files/etc/init.d/commandcode-model-sync"

[ -f "$SYNC_SCRIPT" ] || { echo "missing commandcode-model-sync"; exit 1; }
# The init.d script must be executable in git so OpenWrt procd can start it.
[ "$(git ls-files --stage -- "$SYNC_SCRIPT" | awk '{print $1}')" = "100755" ] || {
	echo "commandcode-model-sync is not marked executable (git mode 100755 required)"
	exit 1
}

sh -n "$SYNC_SCRIPT"

# Static guards.
grep -Fq 'select_model_from_cache' "$SYNC_SCRIPT"
grep -Fq 'settings_is_firmware_managed' "$SYNC_SCRIPT"
grep -Fq 'do_sync' "$SYNC_SCRIPT"
grep -Fq 'commandcode-model-sync' "$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data" || {
	echo "99-auto-mount-data does not enable commandcode-model-sync"
	exit 1
}

# Source the script to get its functions.  The shebang references /etc/rc.common
# but sourcing ignores the shebang; the functions are plain POSIX sh.
# shellcheck disable=SC1090
. "$SYNC_SCRIPT"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# --- Test select_model_from_cache ---

# Case 1: cache with open-source model first.
CACHE1="$TMP_ROOT/cache1.json"
cat >"$CACHE1" <<'EOF'
{"object":"list","data":[{"id":"Qwen/Qwen3.8-Flash","object":"model"},{"id":"anthropic/claude-3","object":"model"}]}
EOF
RESULT="$(select_model_from_cache "$CACHE1")"
[ "$RESULT" = "Qwen/Qwen3.8-Flash" ] || {
	echo "FAIL: select_model_from_cache returned '$RESULT', expected 'Qwen/Qwen3.8-Flash'"
	exit 1
}

# Case 2: cache with closed-source model first, open-source second.
CACHE2="$TMP_ROOT/cache2.json"
cat >"$CACHE2" <<'EOF'
{"object":"list","data":[{"id":"openai/gpt-4o","object":"model"},{"id":"deepseek-ai/DeepSeek-V3","object":"model"}]}
EOF
RESULT="$(select_model_from_cache "$CACHE2")"
[ "$RESULT" = "deepseek-ai/DeepSeek-V3" ] || {
	echo "FAIL: select_model_from_cache returned '$RESULT', expected 'deepseek-ai/DeepSeek-V3'"
	exit 1
}

# Case 3: cache with no open-source models falls back to first.
CACHE3="$TMP_ROOT/cache3.json"
cat >"$CACHE3" <<'EOF'
{"object":"list","data":[{"id":"anthropic/claude-3.5-sonnet","object":"model"},{"id":"openai/gpt-4o","object":"model"}]}
EOF
RESULT="$(select_model_from_cache "$CACHE3")"
[ "$RESULT" = "anthropic/claude-3.5-sonnet" ] || {
	echo "FAIL: no-open-source fallback returned '$RESULT', expected first model"
	exit 1
}

# Case 4: mixed case model names (Llama, Gemma, Mistral).
CACHE4="$TMP_ROOT/cache4.json"
cat >"$CACHE4" <<'EOF'
{"object":"list","data":[{"id":"meta-llama/Llama-3.1-8B","object":"model"}]}
EOF
RESULT="$(select_model_from_cache "$CACHE4")"
[ "$RESULT" = "meta-llama/Llama-3.1-8B" ] || {
	echo "FAIL: Llama model not detected as open-source"
	exit 1
}

CACHE5="$TMP_ROOT/cache5.json"
cat >"$CACHE5" <<'EOF'
{"object":"list","data":[{"id":"google/gemma-2-9b","object":"model"}]}
EOF
RESULT="$(select_model_from_cache "$CACHE5")"
[ "$RESULT" = "google/gemma-2-9b" ] || {
	echo "FAIL: Gemma model not detected as open-source"
	exit 1
}

# Case 5: missing cache file returns failure.
if select_model_from_cache "$TMP_ROOT/nonexistent.json" 2>/dev/null; then
	echo "FAIL: select_model_from_cache succeeded on missing file"
	exit 1
fi

# Case 6: empty/invalid cache returns failure.
: >"$TMP_ROOT/empty.json"
if select_model_from_cache "$TMP_ROOT/empty.json" 2>/dev/null; then
	echo "FAIL: select_model_from_cache succeeded on empty file"
	exit 1
fi

# --- Test settings_is_firmware_managed ---
# After sourcing, the script's internal variables are already set to defaults.
# Override them directly for each test case.

SETTINGS="$TMP_ROOT/settings.json"
MARKER="$TMP_ROOT/.firmware-settings-managed"
printf '%s\n' '{"defaultModel":"test"}' >"$SETTINGS"

# No marker → not managed.
SETTINGS_FILE="$SETTINGS" MANAGED_MARKER="$MARKER" settings_is_firmware_managed && {
	echo "FAIL: settings_is_firmware_managed returned true without marker"
	exit 1
}

# Matching mtime → managed.
touch -r "$SETTINGS" "$MARKER"
SETTINGS_FILE="$SETTINGS" MANAGED_MARKER="$MARKER" settings_is_firmware_managed || {
	echo "FAIL: settings_is_firmware_managed returned false with matching mtime"
	exit 1
}

# Mismatched mtime (user edited) → not managed.
sleep 1
touch "$SETTINGS"
SETTINGS_FILE="$SETTINGS" MANAGED_MARKER="$MARKER" settings_is_firmware_managed && {
	echo "FAIL: settings_is_firmware_managed returned true with mismatched mtime"
	exit 1
}

# --- Test do_sync with mock fetch ---

SYNC_DIR="$TMP_ROOT/sync"
mkdir -p "$SYNC_DIR"
SYNC_CACHE="$SYNC_DIR/commandcode-models.json"
SYNC_SETTINGS="$SYNC_DIR/settings.json"
SYNC_AUTH="$SYNC_DIR/auth.json"
SYNC_MARKER="$SYNC_DIR/.firmware-settings-managed"
MOCK_FETCH="$SYNC_DIR/mock-fetch.sh"
MOCK_BIN="$SYNC_DIR/mockbin"
mkdir -p "$MOCK_BIN"

# Create a mock HTTP client script that writes a predetermined response.
cat >"$MOCK_FETCH" <<'MOCKEOF'
#!/bin/sh
# Mock fetch: writes the content of $MOCK_RESPONSE_FILE to the output file
# specified by -O (uclient-fetch) or -o (curl) or the last arg (wget).
out=""
prev=""
for arg in "$@"; do
	case "$arg" in
		-O) prev="O" ;;
		-o) prev="o" ;;
		*)
			if [ "$prev" = "O" ] || [ "$prev" = "o" ]; then
				out="$arg"
				prev=""
			fi
			;;
	esac
done
# wget uses -qO without space: handle that too.
if [ -z "$out" ]; then
	for arg in "$@"; do
		case "$arg" in
			-O*) out="${arg#-O}" ;;
			-o*) out="${arg#-o}" ;;
		esac
	done
fi
if [ -n "$out" ] && [ -n "${MOCK_RESPONSE_FILE:-}" ] && [ -f "$MOCK_RESPONSE_FILE" ]; then
	cp "$MOCK_RESPONSE_FILE" "$out"
	exit 0
fi
exit 1
MOCKEOF
chmod +x "$MOCK_FETCH"
# Symlink the mock to all three fetch command names so command -v finds it.
ln -sf "$MOCK_FETCH" "$MOCK_BIN/curl"
ln -sf "$MOCK_FETCH" "$MOCK_BIN/wget"
ln -sf "$MOCK_FETCH" "$MOCK_BIN/uclient-fetch"

# Initial state: old cache, firmware-managed settings with old model.
cat >"$SYNC_CACHE" <<'EOF'
{"object":"list","data":[{"id":"Qwen/Qwen3.8-Flash","object":"model"}]}
EOF
cat >"$SYNC_SETTINGS" <<'EOF'
{
  "defaultProvider": "commandcode",
  "defaultModel": "Qwen/Qwen3.8-Flash"
}
EOF
printf '%s\n' '{"apiKey":"user_test_sync_key"}' >"$SYNC_AUTH"
chmod 600 "$SYNC_AUTH"
touch -r "$SYNC_SETTINGS" "$SYNC_MARKER"

# New API response with a different open-source model first.
NEW_RESPONSE="$SYNC_DIR/new-response.json"
cat >"$NEW_RESPONSE" <<'EOF'
{"object":"list","data":[{"id":"deepseek-ai/DeepSeek-V3","object":"model"},{"id":"Qwen/Qwen3.8-Flash","object":"model"}]}
EOF

# Run do_sync with the mock fetch client on PATH.
# Override the script's internal variables directly (they were set at source
# time from COMMANDCODE_* env vars, so re-setting the env vars has no effect).
PATH="$MOCK_BIN:$PATH" MOCK_RESPONSE_FILE="$NEW_RESPONSE" \
	CACHE_FILE="$SYNC_CACHE" SETTINGS_FILE="$SYNC_SETTINGS" \
	AUTH_FILE="$SYNC_AUTH" MANAGED_MARKER="$SYNC_MARKER" \
	MAX_RETRIES=1 MULTICA_INIT="$SYNC_DIR/nonexistent-multica" \
	do_sync

# Cache must be updated.
cmp -s "$NEW_RESPONSE" "$SYNC_CACHE" || {
	echo "FAIL: do_sync did not update the cache file"
	exit 1
}
# defaultModel must be updated to the new first open-source model.
grep -Fq '"defaultModel": "deepseek-ai/DeepSeek-V3"' "$SYNC_SETTINGS" || {
	echo "FAIL: do_sync did not update defaultModel"
	exit 1
}
# Managed marker must be refreshed to match settings mtime.
[ "$(stat -c %Y "$SYNC_SETTINGS")" = "$(stat -c %Y "$SYNC_MARKER")" ] || {
	echo "FAIL: managed marker mtime not refreshed after model update"
	exit 1
}

# --- Test do_sync: user-customized settings are NOT overwritten ---

cat >"$SYNC_SETTINGS" <<'EOF'
{
  "defaultProvider": "commandcode",
  "defaultModel": "user-picked-model"
}
EOF
touch -r "$SYNC_SETTINGS" "$SYNC_MARKER"
sleep 1
touch "$SYNC_SETTINGS"  # simulate user edit → mtime mismatch

PATH="$MOCK_BIN:$PATH" MOCK_RESPONSE_FILE="$NEW_RESPONSE" \
	CACHE_FILE="$SYNC_CACHE" SETTINGS_FILE="$SYNC_SETTINGS" \
	AUTH_FILE="$SYNC_AUTH" MANAGED_MARKER="$SYNC_MARKER" \
	MAX_RETRIES=1 MULTICA_INIT="$SYNC_DIR/nonexistent-multica" \
	do_sync

# Cache is still updated (best-effort), but defaultModel must NOT change.
cmp -s "$NEW_RESPONSE" "$SYNC_CACHE" || {
	echo "FAIL: do_sync did not update cache when settings are user-customized"
	exit 1
}
grep -Fq '"defaultModel": "user-picked-model"' "$SYNC_SETTINGS" || {
	echo "FAIL: do_sync overwrote user-customized defaultModel"
	exit 1
}

# --- Test do_sync: fetch failure keeps existing cache and settings ---

FAIL_FETCH="$SYNC_DIR/mock-fetch-fail.sh"
cat >"$FAIL_FETCH" <<'MOCKEOF'
#!/bin/sh
exit 1
MOCKEOF
chmod +x "$FAIL_FETCH"

# Reset cache to a known state.
cat >"$SYNC_CACHE" <<'EOF'
{"object":"list","data":[{"id":"Qwen/Qwen3.8-Flash","object":"model"}]}
EOF
cat >"$SYNC_SETTINGS" <<'EOF'
{
  "defaultProvider": "commandcode",
  "defaultModel": "Qwen/Qwen3.8-Flash"
}
EOF
touch -r "$SYNC_SETTINGS" "$SYNC_MARKER"

# Use a PATH where the only "fetch" client is the failing one.  We override
# uclient-fetch, curl, and wget by putting the fail script first with those
# names via symlinks.
FAIL_BIN="$SYNC_DIR/failbin"
mkdir -p "$FAIL_BIN"
ln -sf "$FAIL_FETCH" "$FAIL_BIN/uclient-fetch"
ln -sf "$FAIL_FETCH" "$FAIL_BIN/curl"
ln -sf "$FAIL_FETCH" "$FAIL_BIN/wget"

PATH="$FAIL_BIN:$PATH" \
	CACHE_FILE="$SYNC_CACHE" SETTINGS_FILE="$SYNC_SETTINGS" \
	AUTH_FILE="$SYNC_AUTH" MANAGED_MARKER="$SYNC_MARKER" \
	MAX_RETRIES=2 RETRY_INTERVAL=0 \
	MULTICA_INIT="$SYNC_DIR/nonexistent-multica" \
	do_sync

# Cache must be unchanged.
grep -Fq 'Qwen/Qwen3.8-Flash' "$SYNC_CACHE" || {
	echo "FAIL: cache was modified despite fetch failure"
	exit 1
}
# Settings must be unchanged.
grep -Fq '"defaultModel": "Qwen/Qwen3.8-Flash"' "$SYNC_SETTINGS" || {
	echo "FAIL: settings were modified despite fetch failure"
	exit 1
}

# --- Test do_sync: invalid API response keeps existing cache ---

INVALID_RESPONSE="$SYNC_DIR/invalid-response.json"
printf '%s\n' '{"error":"something went wrong"}' >"$INVALID_RESPONSE"

PATH="$MOCK_BIN:$PATH" MOCK_RESPONSE_FILE="$INVALID_RESPONSE" \
	CACHE_FILE="$SYNC_CACHE" SETTINGS_FILE="$SYNC_SETTINGS" \
	AUTH_FILE="$SYNC_AUTH" MANAGED_MARKER="$SYNC_MARKER" \
	MAX_RETRIES=1 MULTICA_INIT="$SYNC_DIR/nonexistent-multica" \
	do_sync

# Cache must still contain the old valid data (not the invalid response).
grep -Fq 'Qwen/Qwen3.8-Flash' "$SYNC_CACHE" || {
	echo "FAIL: invalid API response overwrote valid cache"
	exit 1
}

echo "commandcode model sync tests passed"
