#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/PiCliProxyApiProviderConfig.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
WLG_WORKFLOW="$ROOT_DIR/.github/workflows/WLG-RE-CS-07-BUILD.yml"
PROFILE="$ROOT_DIR/files/etc/profile.d/22-pi-cliproxyapi-provider.sh"
MULTICA="$ROOT_DIR/files/etc/init.d/multica"
MANIFEST="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
FETCH="$ROOT_DIR/Scripts/fetch_node_runtime.sh"

for file in "$SCRIPT" "$WORKFLOW" "$WLG_WORKFLOW" "$PROFILE" "$MULTICA" "$MANIFEST" "$FETCH"; do
	[ -f "$file" ] || { echo "missing required file: $file"; exit 1; }
done
bash -n "$SCRIPT"
sh -n "$PROFILE"
sh -n "$MULTICA"
grep -Fq 'CLIPROXYAPI_API_KEY' "$WORKFLOW"
grep -Fq 'CLIPROXYAPI_API_KEY: ${{ secrets.CLIPROXYAPI_API_KEY }}' "$WLG_WORKFLOW"
grep -Fq 'PiCliProxyApiProviderConfig.sh' "$WORKFLOW"
grep -Fq '@router-for-me/pi-cliproxyapi-provider' "$MANIFEST"
grep -Fq '"npm:@router-for-me/pi-cliproxyapi-provider"' "$FETCH"
grep -Fq 'CLIPROXYAPI_BASE_URL="http://192.168.11.159:8317"' "$PROFILE"
grep -Fq 'CLIPROXYAPI_BASE_URL="$cliproxyapi_base_url"' "$MULTICA"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
CLIPROXYAPI_API_KEY='' bash "$SCRIPT" "$TMP"
[ ! -e "$TMP/etc/pi/agent/cliproxyapi-api-key" ]

CLIPROXYAPI_API_KEY='test-token-value' bash "$SCRIPT" "$TMP" >"$TMP/inject.log"
KEY="$TMP/etc/pi/agent/cliproxyapi-api-key"
[ "$(cat "$KEY")" = 'test-token-value' ]
[ "$(stat -c '%a' "$KEY")" = 600 ]
if grep -Fq 'test-token-value' "$TMP/inject.log"; then
	echo "injector leaked CliProxyAPI token"
	exit 1
fi
if CLIPROXYAPI_API_KEY=$'bad\nkey' bash "$SCRIPT" "$TMP" >/dev/null 2>&1; then
	echo "multiline CliProxyAPI token was accepted"
	exit 1
fi

echo "CliProxyAPI provider configuration tests passed"
