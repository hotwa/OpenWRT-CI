#!/bin/bash
# Inject optional private CliProxyAPI settings into the firmware overlay.
# Values are stored as data, never sourced as shell code.
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
KEY_FILE="$TARGET_FILES/etc/pi/agent/cliproxyapi-api-key"
BASE_FILE="$TARGET_FILES/etc/pi/agent/cliproxyapi-base-url"
BASE_SECRET_MARKER="$TARGET_FILES/etc/pi/agent/cliproxyapi-base-url-secret"
API_KEY="${CLIPROXYAPI_API_KEY:-}"
DEFAULT_BASE_URL="http://192.168.11.159:8317/v1"
BASE_URL="${CLIPROXYAPI_BASE_URL:-$DEFAULT_BASE_URL}"

case "$API_KEY$BASE_URL" in
	*$'\n'*|*$'\r'*)
		echo "ERROR: CliProxyAPI settings must be single-line values" >&2
		exit 1
		;;
esac

BASE_URL="${BASE_URL%/}"
case "$BASE_URL" in
	http://*|https://*) ;;
	*) echo "ERROR: CLIPROXYAPI_BASE_URL must be an http(s) URL" >&2; exit 1 ;;
esac
case "$BASE_URL" in
	*/v1) ;;
	*) BASE_URL="$BASE_URL/v1" ;;
esac

install -d -m 0700 "$(dirname "$KEY_FILE")"
umask 077
printf '%s\n' "$BASE_URL" >"$BASE_FILE"
chmod 0600 "$BASE_FILE"
if [ -n "${CLIPROXYAPI_BASE_URL:-}" ]; then
	printf '%s\n' 'injected' >"$BASE_SECRET_MARKER"
	chmod 0600 "$BASE_SECRET_MARKER"
else
	rm -f -- "$BASE_SECRET_MARKER"
fi
if [ -n "$API_KEY" ]; then
	printf '%s\n' "$API_KEY" >"$KEY_FILE"
	chmod 0600 "$KEY_FILE"
	echo "CliProxyAPI endpoint and token injected into private firmware overlay."
else
	rm -f -- "$KEY_FILE"
	echo "CliProxyAPI endpoint configured; no API token was supplied."
fi
