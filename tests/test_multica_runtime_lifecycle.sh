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
agent_is_usable working
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

# Factory reset may regenerate hostname/hash while preserving /data state. A
# unique managed Agent on the same LAN CIDR is safe to adopt and rebind.
cat > "$TEST_ROOT/factory-agents.json" <<'EOF'
[
  {"id":"agent-legacy","name":"OpenWrt 管家 · RE-SS-01-CONTAINER · 192.168.12.1/24 · a1b2c3","runtime_id":"rt-old","status":"working"},
  {"id":"agent-other-site","name":"OpenWrt 管家 · RE-CS-02 · 192.168.11.1/24 · d4e5f6","runtime_id":"rt-other","status":"idle"}
]
EOF
selected_agent="$(select_agent_id_by_lan_cidr "$TEST_ROOT/factory-agents.json" 'OpenWrt 管家 · RE-SS-01 · 192.168.12.1/24 · 27016a')"
[ "$selected_agent" = 'agent-legacy' ] || {
	echo "factory Agent CIDR selector returned: $selected_agent"
	exit 1
}
cat > "$TEST_ROOT/ambiguous-agents.json" <<'EOF'
[
  {"id":"agent-old-a","name":"OpenWrt 管家 · OLD-A · 192.168.12.1/24 · a1b2c3","runtime_id":"rt-old-a","status":"idle"},
  {"id":"agent-old-b","name":"OpenWrt 管家 · OLD-B · 192.168.12.1/24 · d4e5f6","runtime_id":"rt-old-b","status":"active"}
]
EOF
if select_agent_id_by_lan_cidr "$TEST_ROOT/ambiguous-agents.json" 'OpenWrt 管家 · RE-SS-01 · 192.168.12.1/24 · 27016a' >/dev/null; then
	echo "ambiguous same-CIDR Agents were guessed"
	exit 1
fi

# Exercise the full reconcile path: a dangling cached ID after factory reset
# must update/rebind the one legacy same-site Agent, never create a duplicate.
mkdir -p "$TEST_ROOT/reconcile-data"
printf '%s\n' 'current role instructions' > "$TEST_ROOT/reconcile-data/openwrt-agent.md"
write_agent_state "$TEST_ROOT/reconcile-data/.agent_state" missing-id rt-missing old-hash \
	'OpenWrt 管家 · OLD-HOST · 192.168.12.1/24 · 000000' '[]'
cat > "$TEST_ROOT/mock-multica" <<'EOF'
#!/bin/sh
case "$1 $2" in
	'runtime list')
		printf '%s\n' '[{"id":"rt-current","name":"Pi (OpenWrt-Router)","provider":"pi","status":"online","device_info":"RE-SS-01-12 · 0.85.1","last_seen_at":"2026-09-10T12:00:00Z"}]'
		;;
	'agent list')
		printf '%s\n' '[{"id":"agent-legacy","name":"OpenWrt 管家 · RE-SS-01-CONTAINER · 192.168.12.1/24 · a1b2c3","runtime_id":"rt-old","status":"idle","custom_args":[]}]'
		;;
	'agent update')
		printf '%s\n' "$*" >> "$MOCK_MULTICA_LOG"
		;;
	'agent create')
		printf '%s\n' "unexpected create: $*" >> "$MOCK_MULTICA_LOG"
		exit 1
		;;
	*) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/mock-multica"
: > "$TEST_ROOT/mock-multica.log"
export MOCK_MULTICA_LOG="$TEST_ROOT/mock-multica.log"
MULTICA_BIN="$TEST_ROOT/mock-multica"
DATA_DIR="$TEST_ROOT/reconcile-data"
server_reachable() { return 0; }
runtime_device_name() { printf '%s' 'RE-SS-01-12'; }
try_bootstrap 'https://multica.example' 'Pi (OpenWrt-Router)' pi \
	'OpenWrt 管家 · RE-SS-01 · 192.168.12.1/24 · 27016a' \
	"$TEST_ROOT/reconcile-data/openwrt-agent.md"
grep -Fq 'agent update agent-legacy' "$TEST_ROOT/mock-multica.log" || {
	echo "stale factory state did not rebind the legacy same-CIDR Agent"
	exit 1
}
if grep -Fq 'unexpected create' "$TEST_ROOT/mock-multica.log"; then
	echo "stale factory state created a duplicate Agent"
	exit 1
fi
[ "$(state_value "$TEST_ROOT/reconcile-data/.agent_state" agent_id)" = 'agent-legacy' ]
[ "$(state_value "$TEST_ROOT/reconcile-data/.agent_state" runtime_id)" = 'rt-current' ]

# The backend keeps archived Agents out of the default listing. With the full
# listing, an exact archived saved ID must be restored and updated before any
# same-CIDR migration candidate is considered.
write_agent_state "$TEST_ROOT/reconcile-data/.agent_state" agent-archived rt-old old-hash \
	'OpenWrt 管家 · RE-SS-01 · 192.168.12.1/24 · 27016a' '[]'
cat > "$TEST_ROOT/mock-multica-archived" <<'EOF'
#!/bin/sh
case "$1 $2" in
	'runtime list')
		printf '%s\n' '[{"id":"rt-current","name":"Pi (OpenWrt-Router)","provider":"pi","status":"online","device_info":"RE-SS-01-12 · 0.85.1","last_seen_at":"2026-09-10T12:00:00Z"}]'
		;;
	'agent list')
		case " $* " in *' --include-archived '*) ;; *) exit 2 ;; esac
		printf '%s\n' '[{"id":"agent-archived","name":"OpenWrt 管家 · RE-SS-01 · 192.168.12.1/24 · 27016a","runtime_id":"rt-old","status":"idle","archived_at":"2026-09-09T00:00:00Z","custom_args":[]},{"id":"agent-legacy","name":"OpenWrt 管家 · OLD-HOST · 192.168.12.1/24 · a1b2c3","runtime_id":"rt-old","status":"idle","archived_at":null,"custom_args":[]}]'
		;;
	'agent restore'|'agent update')
		printf '%s\n' "$*" >> "$MOCK_MULTICA_LOG"
		;;
	'agent create')
		printf '%s\n' "unexpected create: $*" >> "$MOCK_MULTICA_LOG"
		exit 1
		;;
	*) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/mock-multica-archived"
: > "$TEST_ROOT/mock-multica.log"
MULTICA_BIN="$TEST_ROOT/mock-multica-archived"
try_bootstrap 'https://multica.example' 'Pi (OpenWrt-Router)' pi \
	'OpenWrt 管家 · RE-SS-01 · 192.168.12.1/24 · 27016a' \
	"$TEST_ROOT/reconcile-data/openwrt-agent.md"
grep -Fq 'agent restore agent-archived' "$TEST_ROOT/mock-multica.log"
grep -Fq 'agent update agent-archived' "$TEST_ROOT/mock-multica.log"
if grep -Eq 'agent update agent-legacy|unexpected create' "$TEST_ROOT/mock-multica.log"; then
	echo "archived saved Agent was not preferred over migration/create"
	exit 1
fi
[ "$(state_value "$TEST_ROOT/reconcile-data/.agent_state" agent_id)" = 'agent-archived' ]

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

# Both create/update must use provider-specific unattended arguments.
# Pi extension flags must never be passed to OpenCode.
custom_args_count="$(grep -c -F -- '--custom-args' "$BOOTSTRAP_SCRIPT")"
[ "$custom_args_count" = '2' ] || {
	echo "multica-agent-bootstrap must pass --custom-args in both agent create and update (found $custom_args_count)"
	exit 1
}
[ "$(runtime_custom_args pi)" = '["--modes","yolo"]' ]
[ "$(runtime_custom_args opencode)" = '["--auto"]' ]
if runtime_custom_args unknown >/dev/null; then
	echo "unknown provider must not inherit unattended permissions"; exit 1
fi
write_agent_state "$TEST_ROOT/policy-state" agent runtime hash name '["--auto"]'
[ "$(state_value "$TEST_ROOT/policy-state" custom_args)" = '["--auto"]' ]
grep -Fq '[ "$state_args" != "$custom_args" ]' "$BOOTSTRAP_SCRIPT"
[ "$(grep -Fc -- '--custom-args "$custom_args"' "$BOOTSTRAP_SCRIPT")" = 2 ]

# A valid local cache must not hide stale arguments changed on the server.
printf '%s\n' '[{"id":"a","custom_args":["--auto"]}]' > "$TEST_ROOT/args.json"
agent_custom_args_match "$TEST_ROOT/args.json" a '["--auto"]'
if agent_custom_args_match "$TEST_ROOT/args.json" a '["--modes","yolo"]'; then
	echo "server argument drift was ignored"; exit 1
fi
printf '%s\n' '[{"id":"a"}]' > "$TEST_ROOT/args.json"
if agent_custom_args_match "$TEST_ROOT/args.json" a '["--auto"]'; then
	echo "missing server arguments must trigger migration"; exit 1
fi
printf '%s\n' 'invalid-json' > "$TEST_ROOT/args.json"
if agent_custom_args_match "$TEST_ROOT/args.json" a '["--auto"]'; then
	echo "malformed server metadata must not pass"; exit 1
fi

echo "multica runtime lifecycle behavior tests passed"
