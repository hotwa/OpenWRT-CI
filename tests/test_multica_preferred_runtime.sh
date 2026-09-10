#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export MULTICA_BOOTSTRAP_LIBRARY_ONLY=1 MULTICA_DATA_DIR="$TMP_ROOT/data"
export MULTICA_PYTHON_BIN="$(command -v python3)"
export MULTICA_BIN="$TMP_ROOT/multica" FIXTURE_ROOT="$TMP_ROOT"
mkdir -p "$MULTICA_DATA_DIR"
cat > "$MULTICA_BIN" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FIXTURE_ROOT/calls"
case "$1 $2" in
 'runtime list') cat "$FIXTURE_ROOT/runtimes.json" ;;
 'agent list') cat "$FIXTURE_ROOT/agents.json" ;;
 'agent create') printf '%s\n' '{"id":"saved-agent"}' ;;
 'agent update') [ ! -e "$FIXTURE_ROOT/fail-update" ] ;;
 *) exit 1 ;;
esac
SH
chmod +x "$MULTICA_BIN"
. "$ROOT/files/usr/sbin/multica-agent-bootstrap"
server_reachable() { return 0; }
runtime_device_name() { printf router; }
log() { printf '%s\n' "$*" >> "$TMP_ROOT/log"; }
printf 'reviewed instructions\n' > "$DATA_DIR/openwrt-agent.md"
printf '%s\n' '[{"id":"rt-pi","name":"Pi","provider":"pi","status":"online"}]' > "$TMP_ROOT/runtimes.json"
printf '[]\n' > "$TMP_ROOT/agents.json"
try_bootstrap https://example.invalid Pi pi router "$DATA_DIR/openwrt-agent.md"
[[ "$(state_value "$DATA_DIR/.agent_state" agent_id)" == saved-agent ]]
[[ "$(grep -c '^agent create' "$TMP_ROOT/calls")" == 1 ]]
printf '%s\n' '[{"id":"saved-agent","name":"router","runtime_id":"rt-pi","status":"idle","custom_args":["--modes","yolo"]}]' > "$TMP_ROOT/agents.json"
sleep_count=0
sleep() {
 [[ "$1" == 30 ]]
 sleep_count=$((sleep_count + 1))
 if [[ "$sleep_count" == 2 ]]; then
  printf '%s\n' '[{"id":"rt-open","name":"OpenCode","provider":"opencode","status":"online"}]' > "$TMP_ROOT/runtimes.json"
 fi
}
reconcile_preferred_runtime https://example.invalid OpenCode router "$DATA_DIR/openwrt-agent.md"
[[ "$sleep_count" == 2 ]]
[[ "$(state_value "$DATA_DIR/.agent_state" runtime_id)" == rt-open ]]
[[ "$(state_value "$DATA_DIR/.agent_state" custom_args)" == '["--auto"]' ]]
[[ "$(grep -c '^agent create' "$TMP_ROOT/calls")" == 1 ]]
[[ "$(grep -c '^agent update saved-agent ' "$TMP_ROOT/calls")" == 1 ]]

# Absent, busy, active (not demonstrably idle), ambiguous and malformed Agents
# cannot trigger a promotion update or substitute/create another Agent.
for fixture in '[]' \
 '[{"id":"other","name":"router","status":"idle"}]' \
 '[{"id":"saved-agent","status":"busy"}]' \
 '[{"id":"saved-agent","status":"active"}]' \
 '[{"id":"saved-agent","status":"idle"},{"id":"saved-agent","status":"idle"}]' \
 'invalid-json'; do
 printf '%s\n' "$fixture" > "$TMP_ROOT/agents.json"
 if try_bootstrap https://example.invalid OpenCode opencode router "$DATA_DIR/openwrt-agent.md" saved-agent; then
  echo 'unsafe promotion accepted'; exit 1
 fi
done
[[ "$(grep -c '^agent create' "$TMP_ROOT/calls")" == 1 ]]
[[ "$(grep -c '^agent update ' "$TMP_ROOT/calls")" == 1 ]]

# Failed updates preserve fallback state, then a later successful retry promotes.
printf '%s\n' '[{"id":"saved-agent","status":"idle","custom_args":["--modes","yolo"]}]' > "$TMP_ROOT/agents.json"
write_agent_state "$DATA_DIR/.agent_state" saved-agent rt-pi oldhash router '["--modes","yolo"]'
touch "$TMP_ROOT/fail-update"
if try_bootstrap https://example.invalid OpenCode opencode router "$DATA_DIR/openwrt-agent.md" saved-agent; then exit 1; fi
[[ "$(state_value "$DATA_DIR/.agent_state" runtime_id)" == rt-pi ]]
rm "$TMP_ROOT/fail-update"
try_bootstrap https://example.invalid OpenCode opencode router "$DATA_DIR/openwrt-agent.md" saved-agent
[[ "$(state_value "$DATA_DIR/.agent_state" runtime_id)" == rt-open ]]

# Permanent unavailability has a finite window and retains the fallback marker.
write_agent_state "$DATA_DIR/.agent_state" saved-agent rt-pi oldhash router '["--modes","yolo"]'
write_success_flag "$DATA_DIR/.agent_initialized"
printf '[]\n' > "$TMP_ROOT/runtimes.json"
sleep_count=0
sleep() { [[ "$1" == 30 ]]; sleep_count=$((sleep_count + 1)); }
reconcile_preferred_runtime https://example.invalid OpenCode router "$DATA_DIR/openwrt-agent.md"
[[ "$sleep_count" == 20 && -f "$DATA_DIR/.agent_initialized" ]]
[[ "$(state_value "$DATA_DIR/.agent_state" runtime_id)" == rt-pi ]]
[[ "$(grep -c '^agent create' "$TMP_ROOT/calls")" == 1 ]]

# Exercise routing in main without network, real sleeps or procd.
cfg() { case "$1" in enabled) printf 1;; runtime_provider) printf '%s' "$provider";; *) printf '%s' "$2";; esac; }
acquire_lock() { return 0; }
render_device_profile() { return 0; }
dynamic_agent_name() { printf router; }
try_bootstrap() { printf '%s\n' "$3" >> "$TMP_ROOT/providers"; [[ "$3" == "$available" ]]; }
reconcile_preferred_runtime() { printf 'promotion\n' >> "$TMP_ROOT/providers"; }
for scenario in pi opencode fallback; do
 : > "$TMP_ROOT/providers"
 provider=opencode; available=opencode
 case "$scenario" in pi) provider=pi; available=pi;; fallback) available=pi;; esac
 main
 case "$scenario" in
  pi) [[ "$(cat "$TMP_ROOT/providers")" == pi ]];;
  opencode) [[ "$(cat "$TMP_ROOT/providers")" == opencode ]];;
  fallback) [[ "$(cat "$TMP_ROOT/providers")" == $'opencode\npi\npromotion' ]];;
 esac
done
echo 'PASS: bounded preferred-runtime promotion, idle-only same-Agent updates, routing and timeout'
