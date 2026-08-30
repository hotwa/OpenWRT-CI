#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_multica_runtime.sh"
BOOTSTRAP_SCRIPT="$ROOT_DIR/files/usr/sbin/multica-agent-bootstrap"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# A malformed version must fail before network access and must never leave a
# fallback executable behind.
mkdir -p "$TEST_ROOT/image"
if MULTICA_VERSION='0.4.35-invalid' MULTICA_ARCH=amd64 \
	GITHUB_WORKSPACE="$ROOT_DIR" bash "$FETCH_SCRIPT" "$TEST_ROOT/image" >/dev/null 2>&1; then
	echo "fetcher accepted an invalid release version"
	exit 1
fi
[ ! -e "$TEST_ROOT/image/usr/local/bin/multica" ] || {
	echo "fetch failure left a Multica executable behind"
	exit 1
}

# Exercise exact runtime selection without depending on a host jsonfilter/jshn
# installation. The fixture deliberately puts a wrong-name and offline runtime
# ahead of the only valid match.
cat > "$TEST_ROOT/jshn.sh" <<'EOF'
json_cleanup() { :; }
json_load() { JSON_FIXTURE="$1"; }
json_get_keys() { eval "$1='1 2 3'"; }
json_select() {
	if [ "$1" = ".." ]; then CURRENT=""; else CURRENT="$1"; fi
}
json_get_var() {
	local variable="$1" field="$2" value=""
	case "$CURRENT:$field" in
		1:id) value='rt-wrong-name' ;;
		1:name) value='Other Router' ;;
		1:provider) value='pi' ;;
		1:status) value='online' ;;
		2:id) value='rt-offline' ;;
		2:name) value='Pi (OpenWrt-Router)' ;;
		2:provider) value='pi' ;;
		2:status) value='offline' ;;
		3:id) value='rt-correct' ;;
		3:name) value='Pi (OpenWrt-Router)' ;;
		3:provider) value='pi' ;;
		3:status) value='online' ;;
	esac
	eval "$variable=\$value"
}
EOF
: > "$TEST_ROOT/runtimes.json"

export MULTICA_BOOTSTRAP_LIBRARY_ONLY=1
export MULTICA_JSHN_LIB="$TEST_ROOT/jshn.sh"
# shellcheck source=/dev/null
. "$BOOTSTRAP_SCRIPT"

selected="$(select_runtime_id "$TEST_ROOT/runtimes.json" 'Pi (OpenWrt-Router)' pi)"
[ "$selected" = 'rt-correct' ] || {
	echo "exact runtime selector returned: $selected"
	exit 1
}
if select_runtime_id "$TEST_ROOT/runtimes.json" 'Pi (OpenWrt-Router)' commandcode >/dev/null; then
	echo "runtime selector accepted the wrong provider"
	exit 1
fi

echo "multica runtime lifecycle behavior tests passed"
