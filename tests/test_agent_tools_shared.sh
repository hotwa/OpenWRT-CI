#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINKER="$ROOT_DIR/files/usr/sbin/agent-tools-link"
README="$ROOT_DIR/files/etc/agent-tools/README.md"
ROLE_CARD="$ROOT_DIR/files/etc/multica/openwrt-agent.md"
AUTO_MOUNT="$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
MULTICA_INIT="$ROOT_DIR/files/etc/init.d/multica"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -x "$LINKER" ] || { echo "missing executable agent-tools-link"; exit 1; }
[ -f "$README" ] || { echo "missing shared tools README"; exit 1; }
sh -n "$LINKER"
grep -Fq 'AGENT_TOOLS_LINK_BIN' "$AUTO_MOUNT"
grep -Fq 'agent-tools-link' "$MULTICA_INIT"
grep -Fq './files/usr/sbin/agent-tools-link ./wrt/files/usr/sbin/agent-tools-link' "$WORKFLOW"
grep -Fq '/data/shared/agent-tools' "$ROLE_CARD"
grep -Fq 'Pi 没有内置 MCP' "$ROLE_CARD"
grep -Fq '04cc174' "$ROLE_CARD"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
mkdir -p "$CASE_ROOT/shared/skills/demo" "$CASE_ROOT/pi/agent" "$CASE_ROOT/commandcode"
printf '%s\n' '---' 'name: demo' '---' > "$CASE_ROOT/shared/skills/demo/SKILL.md"
printf '%s\n' '{"mcpServers":{}}' > "$CASE_ROOT/shared/mcp.json"
AGENT_TOOLS_ROOT="$CASE_ROOT/shared" \
PI_SKILLS_DIR="$CASE_ROOT/pi/agent/skills" \
COMMANDCODE_SKILLS_DIR="$CASE_ROOT/commandcode/skills" \
COMMANDCODE_MCP_FILE="$CASE_ROOT/commandcode/mcp.json" \
AGENT_TOOLS_README_SOURCE="$README" \
  "$LINKER"
[ -L "$CASE_ROOT/pi/agent/skills" ]
[ "$(readlink "$CASE_ROOT/pi/agent/skills")" = "$CASE_ROOT/shared/skills" ]
[ -L "$CASE_ROOT/commandcode/skills" ]
[ -L "$CASE_ROOT/commandcode/mcp.json" ]
[ "$(readlink "$CASE_ROOT/commandcode/mcp.json")" = "$CASE_ROOT/shared/mcp.json" ]

echo "shared Agent Skills/MCP layout tests passed"
