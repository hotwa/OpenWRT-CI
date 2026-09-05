#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/agent-runtime-auto-upgrade"
CONFIG="$ROOT_DIR/files/etc/config/multica"
CRON="$ROOT_DIR/files/etc/crontabs/root"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
ROLE_CARD="$ROOT_DIR/files/etc/multica/openwrt-agent.md"

[ -x "$SCRIPT" ] || { echo "auto-upgrade wrapper is missing or not executable"; exit 1; }
[ -f "$CRON" ] || { echo "nightly runtime cron is missing"; exit 1; }
sh -n "$SCRIPT"
grep -Fq "option auto_runtime_upgrade '1'" "$CONFIG"
grep -Fq '0 3 * * * /usr/sbin/agent-runtime-auto-upgrade' "$CRON"
grep -Fq 'check --json' "$SCRIPT"
grep -Fq 'upgrade --json' "$SCRIPT"
grep -Fq 'an Agent task is active' "$SCRIPT"
grep -Fq './files/etc/crontabs/root ./wrt/files/etc/crontabs/root' "$CORE"
grep -Fq './files/usr/sbin/agent-runtime-auto-upgrade ./wrt/files/usr/sbin/agent-runtime-auto-upgrade' "$CORE"
grep -Fq 'auto_runtime_upgrade' "$ROLE_CARD"
grep -Fq 'RE-SS-01 / RE-CS-02 / RE-CS-07' "$ROLE_CARD"

echo "agent runtime automatic upgrade guards passed"
