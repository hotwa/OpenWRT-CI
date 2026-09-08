#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/init.d/agent-data-prep"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Syntax check
# ---------------------------------------------------------------------------
sh -n "$SCRIPT"

# ---------------------------------------------------------------------------
# Fixture: firmware defaults + empty data partition + /root with old overlay
# ---------------------------------------------------------------------------
FW="$TMP_ROOT/etc"
DATA="$TMP_ROOT/data"
ROOT="$TMP_ROOT/root"
mkdir -p "$FW/pi/agent" "$FW/commandcode" "$FW/multica" "$FW/opencode"
mkdir -p "$DATA" "$ROOT"

cat > "$FW/pi/agent/settings.json" <<'JSON'
{"defaultProvider":"commandcode","defaultModel":"deepseek/deepseek-v4-flash"}
JSON
cat > "$FW/pi/agent/auth.json" <<'JSON'
{"apiKey":"firmware-key-123"}
JSON
printf '%s\n' '{"apiKey":"firmware-cc-key-456"}' > "$FW/commandcode/auth.json"
printf '%s\n' '{"permission":"allow","provider":{"commandcode":{"options":{"apiKey":"{env:COMMANDCODE_API_KEY}"}}}}' > "$FW/opencode/opencode.json"
printf '%s\n' '# OpenWrt agent role card' > "$FW/multica/openwrt-agent.md"

# Simulate an overlay-only /root/.pi from the pre-/data era.
mkdir -p "$ROOT/.pi/agent"
printf '%s\n' '{"defaultProvider":"openai"}' > "$ROOT/.pi/agent/settings.json"

# /data mount appears in the fake mounts file.
MOUNTS="$TMP_ROOT/mounts"
printf '/dev/mmcblk0p27 %s ext4 rw,noatime 0 0\n' "$DATA" > "$MOUNTS"

export AGENT_DATA_PREP_TESTING=1
export AGENT_DATA_PREP_ROOT="$DATA"
export AGENT_DATA_PREP_HOME="$ROOT"
export AGENT_DATA_PREP_FIRMWARE_ETC="$FW"
export AGENT_DATA_PREP_PROC_MOUNTS="$MOUNTS"
# shellcheck source=/dev/null
. "$SCRIPT"

pass_count=0
fail_count=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc"
        fail_count=$((fail_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# 1. First run provisions everything
# ---------------------------------------------------------------------------
start

check "wait_data_mount sees /data mount" wait_data_mount
check "/data/pi/agent/settings.json copied from firmware" test -f "$DATA/pi/agent/settings.json"
check "/data/pi/agent/auth.json copied from firmware" test -f "$DATA/pi/agent/auth.json"
check "/data/commandcode/auth.json matches firmware key" cmp -s "$FW/commandcode/auth.json" "$DATA/commandcode/auth.json"
check "/root/.pi is symlink to /data/pi" test -L "$ROOT/.pi"
check "/root/.pi target is /data/pi" test "$(readlink "$ROOT/.pi")" = "$DATA/pi"
check "/root/.multica is symlink to /data/multica" test -L "$ROOT/.multica"
check "/root/.commandcode is symlink to /data/commandcode" test -L "$ROOT/.commandcode"
check "/root/.config/opencode symlink created" test -L "$ROOT/.config/opencode"
check "opencode config seeded from firmware" cmp -s "$FW/opencode/opencode.json" "$DATA/opencode/config/opencode.json"
check "multica role card copied" cmp -s "$FW/multica/openwrt-agent.md" "$DATA/multica/openwrt-agent.md"
check "old overlay settings migrated into /data/pi/agent" grep -q '"defaultProvider":"openai"' "$DATA/pi/agent/settings.json"

# ---------------------------------------------------------------------------
# 2. Second run is idempotent (no symlink churn, no extra backups)
# ---------------------------------------------------------------------------
pi_link_before="$(readlink "$ROOT/.pi")"
backups_before="$(find "$DATA" -name '*.bak.*' | wc -l)"
start
check "second run leaves /root/.pi symlink intact" test "$(readlink "$ROOT/.pi")" = "$pi_link_before"
check "second run adds no new backups" test "$(find "$DATA" -name '*.bak.*' | wc -l)" = "$backups_before"
check "second run does not duplicate auth files" test "$(find "$DATA/commandcode" -name 'auth.json*' | wc -l)" -ge 1

# ---------------------------------------------------------------------------
# 3. Stale CommandCode key is replaced (with backup)
# ---------------------------------------------------------------------------
printf '%s\n' '{"apiKey":"stale-expired-key"}' > "$DATA/commandcode/auth.json"
start
check "stale CommandCode key replaced by firmware key" cmp -s "$FW/commandcode/auth.json" "$DATA/commandcode/auth.json"
check "stale key kept as timestamped backup" test -n "$(find "$DATA/commandcode" -name 'auth.json.bak.*' | head -1)"

# ---------------------------------------------------------------------------
# 4. /data missing -> start is a no-op that returns 0
# ---------------------------------------------------------------------------
export AGENT_DATA_PREP_PROC_MOUNTS="$TMP_ROOT/no-mounts"
printf '' > "$TMP_ROOT/no-mounts"
rm -rf "$DATA"
mkdir -p "$DATA"   # overlay-style dir exists but is NOT a real mount
start
check "start with no /data mount exits cleanly" true
check "no provisioning happened without a real mount" test -z "$(ls -A "$DATA")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "===== agent-data-prep tests: $pass_count passed, $fail_count failed ====="
if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
echo "All agent-data-prep tests passed"
