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
# Because the CommandCode model list changes as the subscription evolves, we
# never hard-code a defaultModel; an empty string lets Pi pick the provider's
# first advertised model at startup.

set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
PI_ETC_DIR="$TARGET_FILES/etc/pi/agent"
PI_HOME_DIR="$TARGET_FILES/root/.pi/agent"
COMMANDCODE_ETC_DIR="$TARGET_FILES/etc/commandcode"

COMMANDCODE_API_KEY="${COMMANDCODE_API_KEY:-}"

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
	local settings_file="$dir/settings.json"
	local tmp_file

	[ -f "$settings_file" ] || {
		log_error "missing Pi settings file: $settings_file"
		exit 1
	}

	tmp_file="$settings_file.tmp.$$"
	# Set defaultProvider to "commandcode" and clear defaultModel so Pi uses
	# the first model advertised by the dynamic CommandCode catalog.
	jq '.defaultProvider = "commandcode" | .defaultModel = ""' \
		"$settings_file" >"$tmp_file" || {
		rm -f "$tmp_file"
		log_error "failed to patch $settings_file"
		exit 1
	}
	mv "$tmp_file" "$settings_file"
}

require_jq

# Pi agent directories: auth.json + settings.json (defaultProvider flip).
for dir in "$PI_ETC_DIR" "$PI_HOME_DIR"; do
	[ -d "$dir" ] || continue
	write_auth_file "$dir"
	patch_settings "$dir"
done

# CommandCode CLI home: auth.json only (the CLI manages its own settings).
write_auth_file "$COMMANDCODE_ETC_DIR"

log_info "CommandCode zero-config provisioned: Pi defaultProvider=commandcode, auth.json in Pi agent dirs and /etc/commandcode"
