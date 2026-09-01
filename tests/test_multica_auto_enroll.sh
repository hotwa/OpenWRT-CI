#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/files/etc/config/multica"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/multica"
BOOTSTRAP_SCRIPT="$ROOT_DIR/files/usr/sbin/multica-agent-bootstrap"
PROFILE_SCRIPT="$ROOT_DIR/files/usr/sbin/multica-device-profile"
PI_APPEND_LINK="$ROOT_DIR/files/usr/sbin/pi-append-system-link"
AGENT_ETC_MD="$ROOT_DIR/files/etc/multica/openwrt-agent.md"
ENROLL_SCRIPT="$ROOT_DIR/Scripts/MulticaAutoEnroll.sh"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_multica_runtime.sh"
CORE_WF="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$CONFIG_FILE" ] || { echo "missing multica config"; exit 1; }
[ -f "$INIT_SCRIPT" ] || { echo "missing multica init script"; exit 1; }
[ -f "$BOOTSTRAP_SCRIPT" ] || { echo "missing multica-agent-bootstrap"; exit 1; }
[ -x "$PROFILE_SCRIPT" ] || { echo "missing executable multica-device-profile"; exit 1; }
[ -x "$PI_APPEND_LINK" ] || { echo "missing executable pi-append-system-link"; exit 1; }
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
grep -Fq '本机启动时采集的事实' "$AGENT_ETC_MD"
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
grep -Fq 'multica-device-profile write' "$INIT_SCRIPT"
grep -Fq 'pi-append-system-link' "$INIT_SCRIPT"
grep -Fq 'PATH="/data/agent-runtime/current/node/bin:/data/agent-runtime/current/bin:$uv_root:/data/node/bin:/opt/node/bin:/usr/local/bin:/usr/bin:/bin"' "$INIT_SCRIPT" || {
	echo "the multica daemon must export a PATH that prefers agent-runtime generations and node upgrades over the read-only baked /opt/node/bin"
	exit 1
}
grep -Fq "MULTICA_BOOTSTRAP_LOCK_DIR" "$BOOTSTRAP_SCRIPT"
grep -Fq "candidate_status\" = \"online" "$BOOTSTRAP_SCRIPT"
grep -Fq "matches\" -eq 1" "$BOOTSTRAP_SCRIPT"
grep -Fq 'procd_set_param respawn 3600 15 0' "$INIT_SCRIPT"
grep -Fq 'multica-device-profile' "$BOOTSTRAP_SCRIPT"
grep -Fq '.agent_state' "$BOOTSTRAP_SCRIPT"
grep -Fq 'agent update' "$BOOTSTRAP_SCRIPT"
grep -Fq 'active|idle|busy' "$BOOTSTRAP_SCRIPT"
grep -Fq 'Tailnet IPv4 地址池为 `100.64.0.0/10`' "$PROFILE_SCRIPT"
grep -Fq '禁止读取、输出、上传' "$PROFILE_SCRIPT"
grep -Fq '$1 ~ /\//' "$PROFILE_SCRIPT"

bash -n "$FETCH_SCRIPT"
sh -n "$INIT_SCRIPT"
sh -n "$BOOTSTRAP_SCRIPT"
sh -n "$PROFILE_SCRIPT"
sh -n "$PI_APPEND_LINK"

PROFILE_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$PROFILE_TEST_ROOT"' EXIT
MULTICA_TOKEN='must-not-appear-in-agent-instructions' \
	MULTICA_DATA_DIR="$PROFILE_TEST_ROOT/data" MULTICA_BASE_INSTRUCTIONS="$AGENT_ETC_MD" \
	sh "$PROFILE_SCRIPT" write
[ -s "$PROFILE_TEST_ROOT/data/openwrt-agent.md" ] || {
	echo "device profile was not rendered"
	exit 1
}
[ -s "$PROFILE_TEST_ROOT/data/.device_identity" ] || {
	echo "device identity was not rendered"
	exit 1
}
grep -Fq 'Mesh 与凭据安全边界' "$PROFILE_TEST_ROOT/data/openwrt-agent.md"
if grep -Fq 'must-not-appear-in-agent-instructions' "$PROFILE_TEST_ROOT/data/openwrt-agent.md"; then
	echo "device profile leaked a credential environment value"
	exit 1
fi

mkdir -p "$PROFILE_TEST_ROOT/pi/agent"
PI_AGENT_DIR="$PROFILE_TEST_ROOT/pi/agent" PI_ROLE_CARD="$PROFILE_TEST_ROOT/data/openwrt-agent.md" \
	sh "$PI_APPEND_LINK"
[ -L "$PROFILE_TEST_ROOT/pi/agent/APPEND_SYSTEM.md" ] && \
	[ "$(readlink "$PROFILE_TEST_ROOT/pi/agent/APPEND_SYSTEM.md")" = "$PROFILE_TEST_ROOT/data/openwrt-agent.md" ] || {
	echo "Pi system prompt is not linked to the rendered Multica role card"
	exit 1
}

echo "multica auto-enroll & agent bootstrap guard tests passed"
