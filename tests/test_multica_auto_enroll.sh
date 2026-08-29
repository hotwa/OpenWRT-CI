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
grep -Fq 'runtime_name '\''Pi (OpenWrt-Router)'\''' "$CONFIG_FILE"
grep -Fq 'agent_name '\''OpenWrt 管家'\''' "$CONFIG_FILE"
grep -Fq 'daemon start --foreground' "$INIT_SCRIPT"
grep -Fq -- '--max-concurrent-tasks' "$INIT_SCRIPT"
grep -Fq 'multica-agent-bootstrap' "$INIT_SCRIPT"
grep -Fq 'MULTICA_DAEMON_DEVICE_NAME' "$INIT_SCRIPT"
grep -Fq 'MULTICA_WORKSPACES_ROOT' "$INIT_SCRIPT"
grep -Fq 'server_reachable' "$BOOTSTRAP_SCRIPT"
grep -Fq 'agent create' "$BOOTSTRAP_SCRIPT"
grep -Fq 'Qualcomm IPQ6000' "$AGENT_ETC_MD"
grep -Fq 'Headscale' "$AGENT_ETC_MD"
grep -Fq 'rclone' "$AGENT_ETC_MD"
grep -Fq 'MULTICA_TOKEN' "$ENROLL_SCRIPT"
grep -Fq 'MulticaAutoEnroll.sh' "$CORE_WF"
grep -Fq 'fetch_multica_runtime.sh' "$CORE_WF"
grep -Fq 'checksums.txt' "$FETCH_SCRIPT"
grep -Fq 'sha256sum' "$FETCH_SCRIPT"
grep -Fq 'statically linked' "$FETCH_SCRIPT"
grep -Fq -- '-name multica -o -name multica-cli' "$FETCH_SCRIPT"
if grep -Fq 'fallback stub' "$FETCH_SCRIPT" || grep -Fq 'while true; do sleep 3600' "$FETCH_SCRIPT"; then
	echo "multica fetcher must fail closed instead of installing a stub"
	exit 1
fi
grep -Fq 'workspace_id is not configured' "$INIT_SCRIPT"
grep -Fq "max_concurrent_tasks '1'" "$CONFIG_FILE"
grep -Fq 'runtime_provider '\''pi'\''' "$CONFIG_FILE"
grep -Fq "procd_open_instance bootstrap" "$INIT_SCRIPT"
grep -Fq 'PATH="/data/agent-runtime/current/node/bin:/data/agent-runtime/current/bin:/data/node/bin:/opt/node/bin:/usr/local/bin:/usr/bin:/bin"' "$INIT_SCRIPT" || {
	echo "the multica daemon must export a PATH that prefers agent-runtime generations and node upgrades over the read-only baked /opt/node/bin"
	exit 1
}
grep -Fq "MULTICA_BOOTSTRAP_LOCK_DIR" "$BOOTSTRAP_SCRIPT"
grep -Fq "candidate_status\" = \"online" "$BOOTSTRAP_SCRIPT"
grep -Fq "matches\" -eq 1" "$BOOTSTRAP_SCRIPT"

bash -n "$FETCH_SCRIPT"
sh -n "$INIT_SCRIPT"
sh -n "$BOOTSTRAP_SCRIPT"

echo "multica auto-enroll & agent bootstrap guard tests passed"
