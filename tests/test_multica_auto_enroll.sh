#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/files/etc/config/multica"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/multica"
BOOTSTRAP_SCRIPT="$ROOT_DIR/files/usr/sbin/multica-agent-bootstrap"
AGENT_ETC_MD="$ROOT_DIR/files/etc/multica/openwrt-agent.md"
ENROLL_SCRIPT="$ROOT_DIR/Scripts/MulticaAutoEnroll.sh"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_multica_runtime.sh"
CORE_WF="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$CONFIG_FILE" ] || { echo "missing multica config"; exit 1; }
[ -f "$INIT_SCRIPT" ] || { echo "missing multica init script"; exit 1; }
[ -f "$BOOTSTRAP_SCRIPT" ] || { echo "missing multica-agent-bootstrap"; exit 1; }
[ -f "$AGENT_ETC_MD" ] || { echo "missing openwrt-agent.md in etc/multica"; exit 1; }
[ -f "$ENROLL_SCRIPT" ] || { echo "missing MulticaAutoEnroll.sh"; exit 1; }
[ -f "$FETCH_SCRIPT" ] || { echo "missing fetch_multica_runtime.sh"; exit 1; }
[ -f "$CORE_WF" ] || { echo "missing WRT-CORE.yml"; exit 1; }

grep -Fq 'config multica' "$CONFIG_FILE"
grep -Fq 'workspaces_root' "$CONFIG_FILE"
grep -Fq 'runtime_name '\''Pi on OpenWrt'\''' "$CONFIG_FILE"
grep -Fq 'agent_name '\''OpenWrt 管家'\''' "$CONFIG_FILE"
grep -Fq 'daemon start --foreground' "$INIT_SCRIPT"
grep -Fq '--max-concurrent-tasks' "$INIT_SCRIPT"
grep -Fq 'multica-agent-bootstrap' "$INIT_SCRIPT"
grep -Fq 'MULTICA_DAEMON_DEVICE_NAME' "$INIT_SCRIPT"
grep -Fq 'MULTICA_WORKSPACES_ROOT' "$INIT_SCRIPT"
grep -Fq 'wait_for_network' "$BOOTSTRAP_SCRIPT"
grep -Fq 'multica agent create' "$BOOTSTRAP_SCRIPT"
grep -Fq 'Qualcomm IPQ6000' "$AGENT_ETC_MD"
grep -Fq 'Headscale' "$AGENT_ETC_MD"
grep -Fq 'rclone' "$AGENT_ETC_MD"
grep -Fq 'MULTICA_TOKEN' "$ENROLL_SCRIPT"
grep -Fq 'MulticaAutoEnroll.sh' "$CORE_WF"
grep -Fq 'fetch_multica_runtime.sh' "$CORE_WF"

echo "multica auto-enroll & agent bootstrap guard tests passed"