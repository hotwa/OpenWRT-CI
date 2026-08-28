#!/bin/bash
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
CONFIG_FILE="$TARGET_FILES/etc/config/multica"

MULTICA_TOKEN="${MULTICA_TOKEN:-${MULTICA_PAT:-}}"
MULTICA_SERVER_URL="${MULTICA_SERVER_URL:-https://multica.lucky.jmsu.top}"
MULTICA_APP_URL="${MULTICA_APP_URL:-https://multica.lucky.jmsu.top}"
MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-}"
MULTICA_DEVICE_NAME="${MULTICA_DEVICE_NAME:-}"
MULTICA_RUNTIME_NAME="${MULTICA_RUNTIME_NAME:-Pi on OpenWrt}"
MULTICA_AGENT_NAME="${MULTICA_AGENT_NAME:-OpenWrt 管家}"
MULTICA_WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT:-/data/multica/workspaces}"

if [ -z "$MULTICA_TOKEN" ]; then
	echo "multica auto-enroll: MULTICA_TOKEN is empty; leaving multica disabled"
	exit 0
fi

set_config_option() {
	local option="$1"
	local value="$2"
	if grep -q "^[[:space:]]*option ${option} " "$CONFIG_FILE"; then
		sed -i "s#^[[:space:]]*option ${option} .*#	option ${option} '${value}'#" "$CONFIG_FILE"
	else
		printf "\toption %s '%s'\n" "$option" "$value" >> "$CONFIG_FILE"
	fi
}

[ -f "$CONFIG_FILE" ] || {
	echo "multica auto-enroll: missing $CONFIG_FILE" >&2
	exit 1
}

set_config_option enabled 1
set_config_option server_url "$MULTICA_SERVER_URL"
set_config_option app_url "$MULTICA_APP_URL"
set_config_option token "$MULTICA_TOKEN"
set_config_option workspace_id "$MULTICA_WORKSPACE_ID"
set_config_option device_name "$MULTICA_DEVICE_NAME"
set_config_option runtime_name "$MULTICA_RUNTIME_NAME"
set_config_option agent_name "$MULTICA_AGENT_NAME"
set_config_option workspaces_root "$MULTICA_WORKSPACES_ROOT"

echo "multica auto-enroll: enabled for $MULTICA_SERVER_URL with PAT token configured"