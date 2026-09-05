#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINKER="$ROOT_DIR/files/usr/sbin/commandcode-role-link"
AUTO_MOUNT="$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
MULTICA_INIT="$ROOT_DIR/files/etc/init.d/multica"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
ROLE_CARD="$ROOT_DIR/files/etc/multica/openwrt-agent.md"

[ -x "$LINKER" ] || { echo "missing executable commandcode-role-link"; exit 1; }
sh -n "$LINKER"
grep -Fq 'COMMANDCODE_ROLE_LINK_BIN' "$AUTO_MOUNT"
grep -Fq 'commandcode-role-link' "$MULTICA_INIT"
grep -Fq './files/usr/sbin/commandcode-role-link ./wrt/files/usr/sbin/commandcode-role-link' "$WORKFLOW"
grep -Fq './wrt/files/usr/sbin/commandcode-role-link' "$WORKFLOW"
grep -Fq '5cfbcb3' "$ROLE_CARD"
grep -Fq 'CommandCode' "$ROLE_CARD"

CASE_ROOT="$(mktemp -d)"
trap 'rm -rf "$CASE_ROOT"' EXIT
mkdir -p "$CASE_ROOT/data/commandcode" "$CASE_ROOT/data/multica"
printf '%s\n' role-card > "$CASE_ROOT/data/multica/openwrt-agent.md"
COMMANDCODE_HOME="$CASE_ROOT/data/commandcode" \
COMMANDCODE_ROLE_CARD="$CASE_ROOT/data/multica/openwrt-agent.md" \
  "$LINKER"
[ -L "$CASE_ROOT/data/commandcode/AGENTS.md" ]
[ "$(readlink "$CASE_ROOT/data/commandcode/AGENTS.md")" = "$CASE_ROOT/data/multica/openwrt-agent.md" ]

# Never overwrite an administrator's existing regular AGENTS.md.
rm -f "$CASE_ROOT/data/commandcode/AGENTS.md"
printf '%s\n' custom-policy > "$CASE_ROOT/data/commandcode/AGENTS.md"
COMMANDCODE_HOME="$CASE_ROOT/data/commandcode" \
COMMANDCODE_ROLE_CARD="$CASE_ROOT/data/multica/openwrt-agent.md" \
  "$LINKER" >/dev/null 2>&1
grep -Fq custom-policy "$CASE_ROOT/data/commandcode/AGENTS.md"

echo "CommandCode role-card link tests passed"
