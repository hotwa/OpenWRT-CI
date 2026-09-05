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

# The controller returns top-level JSON arrays.  The fixture deliberately puts
# a wrong-name and offline runtime ahead of the only exact match.
cat > "$TEST_ROOT/runtimes.json" <<'EOF'
[
  {"id":"rt-old-device","name":"Other Router","provider":"pi","status":"online","device_info":"OTHER · 0.84.4","last_seen_at":"2026-09-05T09:00:00Z"},
  {"id":"rt-offline","name":"Pi (OpenWrt-Router)","provider":"pi","status":"offline","device_info":"RE-SS-01-12 · 0.84.4","last_seen_at":"2026-09-05T09:30:00Z"},
  {"id":"rt-correct","name":"Renamed runtime","provider":"pi","status":"online","device_info":"re-ss-01-12 · 0.85.0","last_seen_at":"2026-09-05T10:00:00Z"},
  {"id":"rt-newer","name":"Another runtime name","provider":"pi","status":"online","device_info":"RE-SS-01-12 · 0.85.0","last_seen_at":"2026-09-05T11:00:00Z"}
]
EOF
cat > "$TEST_ROOT/agents.json" <<'EOF'
[
  {"id":"agent-idle","name":"OpenWrt 管家 · RE-SS-01","runtime_id":"rt-old","status":"idle"},
  {"id":"agent-archived","name":"Archived Router","runtime_id":"rt-correct","status":"archived"}
]
EOF

export MULTICA_BOOTSTRAP_LIBRARY_ONLY=1
export MULTICA_PYTHON_BIN="$(command -v python3)"
# shellcheck source=/dev/null
. "$BOOTSTRAP_SCRIPT"

selected="$(select_runtime_id "$TEST_ROOT/runtimes.json" 'Pi (OpenWrt-Router)' pi 'RE-SS-01-12')"
[ "$selected" = 'rt-newer' ] || {
	echo "exact runtime selector returned: $selected"
	exit 1
}
if select_runtime_id "$TEST_ROOT/runtimes.json" 'Pi (OpenWrt-Router)' commandcode 'RE-SS-01-12' >/dev/null; then
	echo "runtime selector accepted the wrong provider"
	exit 1
fi
selected="$(select_runtime_id "$TEST_ROOT/runtimes.json" 'Pi (New Firmware Name)' pi 'RE-SS-01-12')"
[ "$selected" = 'rt-newer' ] || {
	echo "runtime selector did not fall back to the stable device identity: $selected"
	exit 1
}

# The controller reports normal Agents as idle until they receive a task; idle
# must not be mistaken for an absent Agent and trigger duplicate registration.
agent_is_usable idle
if agent_is_usable archived; then
	echo "archived Agent was treated as usable"
	exit 1
fi
if selected_agent="$(select_agent_id "$TEST_ROOT/agents.json" 'OpenWrt 管家 · RE-SS-01' rt-correct)"; then
	echo "same-name Agent with an old runtime was treated as an exact match"
	exit 1
fi
selected_agent="$(select_agent_id_by_name "$TEST_ROOT/agents.json" 'OpenWrt 管家 · RE-SS-01')"
[ "$selected_agent" = 'agent-idle' ] || {
	echo "idle Agent selector returned: $selected_agent"
	exit 1
}

# The first-boot worker runs with `set -u`.  A missing optional instructions
# argument must make one bootstrap attempt retryable, never abort its worker.
if ! MULTICA_BOOTSTRAP_LIBRARY_ONLY=1 MULTICA_PYTHON_BIN="$(command -v python3)" \
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
