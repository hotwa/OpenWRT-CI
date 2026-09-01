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
json_get_keys() {
	case "$JSON_FIXTURE" in
		agents) eval "$1='1 2'" ;;
		*) eval "$1='1 2 3'" ;;
	esac
}
json_select() {
	if [ "$1" = ".." ]; then CURRENT=""; else CURRENT="$1"; fi
}
json_get_var() {
	local variable="$1" field="$2" value=""
	case "$JSON_FIXTURE" in
		agents)
			case "$CURRENT:$field" in
				1:id) value='agent-idle' ;;
				1:name) value='OpenWrt 管家 · RE-SS-01' ;;
				1:runtime_id) value='rt-correct' ;;
				1:status) value='idle' ;;
				2:id) value='agent-archived' ;;
				2:name) value='Archived Router' ;;
				2:runtime_id) value='rt-correct' ;;
				2:status) value='archived' ;;
			esac
			;;
		*)
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
			;;
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

# The controller reports normal Agents as idle until they receive a task; idle
# must not be mistaken for an absent Agent and trigger duplicate registration.
agent_is_usable idle
if agent_is_usable archived; then
	echo "archived Agent was treated as usable"
	exit 1
fi
printf 'agents' > "$TEST_ROOT/agents.json"
selected_agent="$(select_agent_id "$TEST_ROOT/agents.json" 'OpenWrt 管家 · RE-SS-01' rt-correct)"
[ "$selected_agent" = 'agent-idle' ] || {
	echo "idle Agent selector returned: $selected_agent"
	exit 1
}

# The first-boot worker runs with `set -u`.  A missing optional instructions
# argument must make one bootstrap attempt retryable, never abort its worker.
if ! MULTICA_BOOTSTRAP_LIBRARY_ONLY=1 MULTICA_JSHN_LIB="$TEST_ROOT/jshn.sh" \
	bash -c '
		. "$1"
		server_reachable() { return 1; }
		if try_bootstrap "https://multica.example" "Pi" pi "router"; then
			exit 1
		fi
	' bash "$BOOTSTRAP_SCRIPT"; then
	echo "bootstrap aborts when an optional instructions path is absent"
	exit 1
fi

grep -Fq 'try_bootstrap "$server_url" "$expected_runtime_name" "$expected_provider" "$agent_name" "$instructions_file"' "$BOOTSTRAP_SCRIPT" || {
	echo "bootstrap main does not pass its reviewed instructions file"
	exit 1
}

echo "multica runtime lifecycle behavior tests passed"
