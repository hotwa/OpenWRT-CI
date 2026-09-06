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
# time, cache it in the firmware, and select the first open-source model.  A
# runtime init.d script (commandcode-model-sync) refreshes the cache and the
# default model after the network comes up.

set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
PI_ETC_DIR="$TARGET_FILES/etc/pi/agent"
PI_HOME_DIR="$TARGET_FILES/root/.pi/agent"
COMMANDCODE_ETC_DIR="$TARGET_FILES/etc/commandcode"

COMMANDCODE_API_KEY="${COMMANDCODE_API_KEY:-}"
COMMANDCODE_MODELS_URL="${COMMANDCODE_MODELS_URL:-https://api.commandcode.ai/provider/v1/models}"
# For tests: if set to a readable file, use it as the cache instead of fetching.
COMMANDCODE_MODEL_CACHE_INPUT="${COMMANDCODE_MODEL_CACHE_INPUT:-}"

# Open-source model identifier patterns (case-insensitive substring match).
# Keep this list in sync with the runtime selectors in 99-auto-mount-data and
# commandcode-model-sync.
OPEN_SOURCE_PATTERNS='qwen|llama|mistral|deepseek|gemma'

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

# Select the first open-source model from a cache JSON file.  Falls back to the
# first model in the list if no open-source model matches, and ultimately to
# Qwen/Qwen3.8-Flash if the cache is unusable.
select_open_source_model() {
	local cache_file="$1"
	local selected

	# First pass: first model whose id matches an open-source pattern.
	selected="$(jq -r --arg pat "$OPEN_SOURCE_PATTERNS" \
		'.data[]?.id | select(ascii_downcase | test($pat))' \
		"$cache_file" 2>/dev/null | head -1)"
	if [ -n "$selected" ] && [ "$selected" != "null" ]; then
		printf '%s\n' "$selected"
		return 0
	fi

	# Second pass: first model in the list, regardless of licensing.
	selected="$(jq -r '.data[0].id' "$cache_file" 2>/dev/null)"
	if [ -n "$selected" ] && [ "$selected" != "null" ]; then
		printf '%s\n' "$selected"
		return 0
	fi

	# Ultimate fallback.
	printf '%s\n' "Qwen/Qwen3.8-Flash"
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
	# selected open-source model from the cached catalog.
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

DEFAULT_MODEL="$(select_open_source_model "$CACHE_FILE")"
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

log_info "CommandCode zero-config provisioned: Pi defaultProvider=commandcode, defaultModel=$DEFAULT_MODEL, model cache embedded"
