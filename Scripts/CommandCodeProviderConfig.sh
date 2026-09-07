#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Inject the CommandCode provider API key into the firmware so both Pi and the
# CommandCode CLI work with zero manual configuration after flashing.
#
# - Pi's pi-commandcode-provider extension reads ~/.pi/agent/auth.json and
#   registers a "commandcode" provider with a dynamically fetched model catalog.
# - The CommandCode CLI (cmd / cmdc) reads ~/.commandcode/auth.json.
# - Both home directories are symlinked onto /data at first boot, so the key
#   persists across reboots and upgrades.
#
# Because the CommandCode model list changes as the subscription evolves, we no
# longer hard-code defaultModel.  Instead we fetch the model catalog at build
# time, cache it in the firmware, and select a preferred model using ordered
# wildcard patterns: flash models (cheap + fast) are preferred, with
# deepseek/qwen/glm flash models first, then any flash model, then any "pro"
# model.  The live catalog always contains a flash model, so no built-in
# fallback is needed.  A runtime init.d script (commandcode-model-sync)
# refreshes the cache and the default model after the network comes up.

set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
PI_ETC_DIR="$TARGET_FILES/etc/pi/agent"
PI_HOME_DIR="$TARGET_FILES/root/.pi/agent"
COMMANDCODE_ETC_DIR="$TARGET_FILES/etc/commandcode"

COMMANDCODE_API_KEY="${COMMANDCODE_API_KEY:-}"
COMMANDCODE_MODELS_URL="${COMMANDCODE_MODELS_URL:-https://api.commandcode.ai/provider/v1/models}"
# For tests: if set to a readable file, use it as the cache instead of fetching.
COMMANDCODE_MODEL_CACHE_INPUT="${COMMANDCODE_MODEL_CACHE_INPUT:-}"

# Preferred model patterns in priority order (case-insensitive regex, matched
# against the model id).  After these three, the selector falls through to any
# flash model and then any "pro" model.  No built-in fallback: the live catalog
# always contains a flash model, and a missing match indicates an API problem.
# Keep this list in sync with the runtime selectors in 99-auto-mount-data and
# commandcode-model-sync.
MODEL_PREFERENCE_PATTERNS='deepseek/.*flash.* qwen/.*flash.* glm.*flash.*'

# Built-in minimal fallback cache used when the build-time API fetch fails.
# Must contain at least one open-source model so defaultModel can be resolved.
BUILTIN_FALLBACK_CACHE='{"object":"list","data":[{"id":"Qwen/Qwen3.8-Flash","object":"model","owned_by":"qwen"},{"id":"Qwen/Qwen3.8-27B","object":"model","owned_by":"qwen"}]}'

log_info() {
	printf 'INFO: [commandcode-provider] %s\n' "$*"
}

log_error() {
	printf 'ERROR: [commandcode-provider] %s\n' "$*" >&2
}

if [ -z "$COMMANDCODE_API_KEY" ]; then
	echo "commandcode provider: COMMANDCODE_API_KEY is empty; leaving Pi default provider unchanged"
	exit 0
fi

# Basic shape check: CommandCode Provider API keys start with "user_".
case "$COMMANDCODE_API_KEY" in
	user_*) ;;
	*)
		log_error "COMMANDCODE_API_KEY does not look like a CommandCode Provider API key (expected user_... prefix)"
		exit 1
		;;
esac

require_jq() {
	command -v jq >/dev/null 2>&1 || {
		log_error "jq is required but not found"
		exit 1
	}
}

# Fetch the model catalog from the CommandCode API.  Returns 0 and writes the
# JSON to $1 on success; returns 1 on any failure (network, auth, bad JSON).
fetch_model_cache() {
	local output_file="$1"
	local tmp_file="${output_file}.tmp.$$"

	# Test hook: use a pre-supplied cache file instead of hitting the network.
	if [ -n "$COMMANDCODE_MODEL_CACHE_INPUT" ] && [ -r "$COMMANDCODE_MODEL_CACHE_INPUT" ]; then
		cp "$COMMANDCODE_MODEL_CACHE_INPUT" "$output_file" || return 1
		return 0
	fi

	command -v curl >/dev/null 2>&1 || return 1

	curl -sf --max-time 15 \
		-H "Authorization: Bearer $COMMANDCODE_API_KEY" \
		-o "$tmp_file" \
		"$COMMANDCODE_MODELS_URL" 2>/dev/null || {
		rm -f "$tmp_file"
		return 1
	}

	# Validate: must be a JSON object with a "data" array.
	jq -e '.data | type == "array" and length >= 1' "$tmp_file" >/dev/null 2>&1 || {
		rm -f "$tmp_file"
		return 1
	}

	mv "$tmp_file" "$output_file"
	return 0
}

# Select the preferred default model from a cache JSON file using ordered
# wildcard patterns.  Matching passes, in priority order (all case-insensitive):
#   1. deepseek flash  (deepseek/.*flash.*)
#   2. qwen flash      (qwen/.*flash.*)
#   3. glm flash       (glm.*flash.*)
#   4. any flash model (any provider, e.g. stepfun/Step-3.7-Flash)
#   5. any "pro" model (e.g. deepseek/deepseek-v4-pro, xiaomi/mimo-v2.5-pro)
# No built-in fallback: the live catalog always contains a flash model.  Returns
# 0 with the model id on stdout; returns 1 if no pattern matches (caller must
# decide how to handle a catalog with neither flash nor pro models).
select_preferred_model() {
	local cache_file="$1"
	local selected pat

	# Passes 1-3: preferred flash patterns in priority order.
	for pat in $MODEL_PREFERENCE_PATTERNS; do
		selected="$(jq -r --arg p "$pat" \
			'.data[]?.id | select(ascii_downcase | test($p))' \
			"$cache_file" 2>/dev/null | head -1)"
		if [ -n "$selected" ] && [ "$selected" != "null" ]; then
			printf '%s\n' "$selected"
			return 0
		fi
	done

	# Pass 4: any model with "flash" in the id (any provider).
	selected="$(jq -r \
		'.data[]?.id | select(ascii_downcase | test("flash"))' \
		"$cache_file" 2>/dev/null | head -1)"
	if [ -n "$selected" ] && [ "$selected" != "null" ]; then
		printf '%s\n' "$selected"
		return 0
	fi

	# Pass 5: any model with "pro" in the id.
	selected="$(jq -r \
		'.data[]?.id | select(ascii_downcase | test("pro"))' \
		"$cache_file" 2>/dev/null | head -1)"
	if [ -n "$selected" ] && [ "$selected" != "null" ]; then
		printf '%s\n' "$selected"
		return 0
	fi

	# No match: caller decides.
	return 1
}

write_auth_file() {
	local dir="$1"
	local auth_file="$dir/auth.json"

	mkdir -p "$dir"
	umask 077
	# The pi-commandcode-provider extension accepts {"apiKey": "user_..."}.
	printf '%s\n' "$(jq -n --arg key "$COMMANDCODE_API_KEY" '{apiKey: $key}')" >"$auth_file"
	chmod 0600 "$auth_file"
}

patch_settings() {
	local dir="$1"
	local default_model="$2"
	local settings_file="$dir/settings.json"
	local tmp_file

	[ -f "$settings_file" ] || {
		log_error "missing Pi settings file: $settings_file"
		exit 1
	}

	tmp_file="$settings_file.tmp.$$"
	# Set defaultProvider to "commandcode" and defaultModel to the dynamically
	# selected preferred model from the cached catalog.
	jq --arg model "$default_model" \
		'.defaultProvider = "commandcode" | .defaultModel = $model' \
		"$settings_file" >"$tmp_file" || {
		rm -f "$tmp_file"
		log_error "failed to patch $settings_file"
		exit 1
	}
	mv "$tmp_file" "$settings_file"
}

require_jq

# --- Pre-built model cache ---------------------------------------------------
# Fetch the CommandCode model catalog at build time and embed it in the
# firmware so the first-boot selector has a model list even without network.
# If the fetch fails (no network, bad key, etc.), fall back to a minimal
# built-in cache that always contains at least one open-source model.
CACHE_FILE="$PI_ETC_DIR/commandcode-models.json"
mkdir -p "$PI_ETC_DIR"

if fetch_model_cache "$CACHE_FILE"; then
	log_info "fetched CommandCode model catalog from API"
else
	log_info "CommandCode API fetch failed; using built-in fallback model cache"
	printf '%s\n' "$BUILTIN_FALLBACK_CACHE" >"$CACHE_FILE"
fi

DEFAULT_MODEL="$(select_preferred_model "$CACHE_FILE")" || {
	log_error "no preferred model (flash/pro) found in model catalog; refusing to guess"
	exit 1
}
log_info "selected default model from catalog: $DEFAULT_MODEL"

# Pi agent directories: auth.json + settings.json (defaultProvider flip +
# dynamically selected defaultModel).
for dir in "$PI_ETC_DIR" "$PI_HOME_DIR"; do
	[ -d "$dir" ] || continue
	write_auth_file "$dir"
	patch_settings "$dir" "$DEFAULT_MODEL"
done

# CommandCode CLI home: auth.json only (the CLI manages its own settings).
write_auth_file "$COMMANDCODE_ETC_DIR"

log_info "CommandCode zero-config provisioned: Pi defaultProvider=commandcode, defaultModel=$DEFAULT_MODEL (preferred flash-first), model cache embedded"
