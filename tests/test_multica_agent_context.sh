#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin"
# Discovery must not execute potentially installing wrappers or sync tools.
for tool in opencode rsync rclone; do
    printf '#!/bin/sh\nexit 91\n' > "$TMP_ROOT/bin/$tool"
    chmod +x "$TMP_ROOT/bin/$tool"
done
export PATH="$TMP_ROOT/bin:$PATH"
export MULTICA_DEVICE_PROFILE_LIBRARY_ONLY=1
. "$ROOT/files/usr/sbin/multica-device-profile"
for tool in opencode rsync rclone; do
    result="$(tool_line "$tool")"
    [[ "$result" == *"$TMP_ROOT/bin/$tool"* ]] || { echo "missing discovered $tool"; exit 1; }
done
tool_line absent-openwrt-fixture | grep -Fq '未在当前 PATH 找到'
uci() { return 1; }
unset MULTICA_WORKSPACES_ROOT
[[ "$(workspaces_root)" = /data/multica/workspaces ]]
MULTICA_WORKSPACES_ROOT=/data/custom/workspaces
[[ "$(workspaces_root)" = /data/custom/workspaces ]]
MULTICA_WORKSPACES_ROOT=/data/../root
[[ "$(workspaces_root)" = /data/multica/workspaces ]]

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
from pathlib import Path
import os
import re
import subprocess
import sys

root, temp = map(Path, sys.argv[1:])
init = (root / "files/etc/init.d/multica").read_text()
profile = (root / "files/usr/sbin/multica-device-profile").read_text()
role = (root / "files/etc/multica/openwrt-agent.md").read_text()
agent_path = re.search(r'agent_path="([^"]+)"', init).group(1)
entries = agent_path.split(":")
assert entries[:2] == ["/data/agent-runtime/current/node/bin", "/data/agent-runtime/current/bin"]
for entry in ("$uv_root", "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"):
    assert entry in entries, entry
assert init.count('PATH="$agent_path"') == 3, "renderer, daemon and bootstrap must share PATH"
assert 'MULTICA_WORKSPACES_ROOT="$workspaces_root" /usr/sbin/multica-device-profile write' in init
command = re.search(r"procd_set_param command /bin/sh -c '([^']+)' multica-launch", init).group(1)
cwd = temp / "workspaces with spaces"
cwd.mkdir()
env = dict(os.environ, MULTICA_WORKSPACES_ROOT=str(cwd))
result = subprocess.run(["sh", "-c", command, "multica-launch", "sh", "-c",
                         'printf "%s\\n%s\\n" "$PWD" "$1"', "probe", "argument with spaces"],
                        env=env, text=True, capture_output=True)
assert result.returncode == 0, result.stderr
assert result.stdout.splitlines() == [str(cwd), "argument with spaces"]
env["MULTICA_WORKSPACES_ROOT"] = str(temp / "not-created")
result = subprocess.run(["sh", "-c", command, "multica-launch", "echo", "must-not-start"],
                        env=env, text=True, capture_output=True)
assert result.returncode != 0 and "must-not-start" not in result.stdout
for term in ("rsync", "rclone", "rg", "fd", "jq", "opencode", "node", "uv", "sha256sum"):
    assert term in profile and term in role, term
for term in ("/usr/sbin", "/sbin", "pwd -P", "XDG_CONFIG_HOME", "APPEND_SYSTEM.md",
             "/data/opencode/config/opencode/AGENTS.md", "run_without_bridge=1"):
    assert term in role, term
print("PASS: Agent PATH/CWD, tool discovery without execution, and shared context contract")
PY
