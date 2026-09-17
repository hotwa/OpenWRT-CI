#!/bin/bash
# Inject the optional private CliProxyAPI token into the firmware overlay.
# The endpoint is deliberately public configuration; only this raw token file
# is secret-bearing.  It is read as data, never sourced as shell code.
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
KEY_FILE="$TARGET_FILES/etc/pi/agent/cliproxyapi-api-key"
API_KEY="${CLIPROXYAPI_API_KEY:-}"

if [ -z "$API_KEY" ]; then
	rm -f -- "$KEY_FILE"
	echo "CliProxyAPI provider token not supplied; endpoint remains available without credentials."
	exit 0
fi

case "$API_KEY" in
	*$'\n'*|*$'\r'*)
		echo "ERROR: CLIPROXYAPI_API_KEY must be a single line" >&2
		exit 1
		;;
esac

install -d -m 0700 "$(dirname "$KEY_FILE")"
umask 077
tmp_file="$(mktemp "${KEY_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "$tmp_file"' EXIT HUP INT TERM
printf '%s\n' "$API_KEY" >"$tmp_file"
chmod 0600 "$tmp_file"
mv -f "$tmp_file" "$KEY_FILE"
trap - EXIT HUP INT TERM
echo "CliProxyAPI provider token injected into private firmware overlay."
