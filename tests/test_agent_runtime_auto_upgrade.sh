#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/usr/sbin/agent-runtime-auto-upgrade"
CONFIG="$ROOT_DIR/files/etc/config/multica"
CRON="$ROOT_DIR/files/etc/crontabs/root"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
ROLE_CARD="$ROOT_DIR/files/etc/multica/openwrt-agent.md"
LOG_HYGIENE="$ROOT_DIR/files/usr/sbin/multica-log-hygiene"
RUNTIME_GUARD="$ROOT_DIR/files/usr/sbin/multica-runtime-guard"
LOGD_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/93-logd-ring-size"
CRON_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/95-multica-maintenance-cron"

[ -x "$SCRIPT" ] || { echo "auto-upgrade wrapper is missing or not executable"; exit 1; }
[ -f "$CRON" ] || { echo "nightly runtime cron is missing"; exit 1; }
sh -n "$SCRIPT"
grep -Fq "option auto_runtime_upgrade '1'" "$CONFIG"
grep -Fq '0 3 * * * /usr/sbin/agent-runtime-auto-upgrade' "$CRON"
grep -Fq '*/5 * * * * /usr/sbin/multica-runtime-guard #multica runtime guard' "$CRON"
grep -Fq '*/30 * * * * /usr/sbin/multica-log-hygiene #multica log hygiene' "$CRON"
[ -x "$LOG_HYGIENE" ] || { echo "multica log hygiene helper is missing or not executable"; exit 1; }
sh -n "$LOG_HYGIENE"
sh -n "$RUNTIME_GUARD"
[ -x "$LOGD_DEFAULTS" ] || { echo "logd ring-size defaults are missing or not executable"; exit 1; }
[ -x "$CRON_DEFAULTS" ] || { echo "Multica cron defaults are missing or not executable"; exit 1; }
sh -n "$LOGD_DEFAULTS"
sh -n "$CRON_DEFAULTS"
grep -Fq "system.@system[0].log_size=256" "$LOGD_DEFAULTS"
grep -Fq '#multica runtime guard' "$CRON_DEFAULTS"
grep -Fq '#multica log hygiene' "$CRON_DEFAULTS"
grep -Fq 'LOCK_DIR="/var/run/multica-maintenance.lock"' "$SCRIPT"
grep -Fq 'LOCK_DIR="/var/run/multica-maintenance.lock"' "$LOG_HYGIENE"
grep -Fq 'LOCK_DIR="/var/run/multica-maintenance.lock"' "$RUNTIME_GUARD"
if grep -Fq 'config.json' "$LOG_HYGIENE"; then
	echo "log hygiene helper must not reference Multica config.json"
	exit 1
fi
grep -Fq 'check --json' "$SCRIPT"
grep -Fq 'upgrade --json' "$SCRIPT"
grep -Fq 'an Agent task is active' "$SCRIPT"
grep -Fq './files/etc/crontabs/root ./wrt/files/etc/crontabs/root' "$CORE"
grep -Fq './files/usr/sbin/agent-runtime-auto-upgrade ./wrt/files/usr/sbin/agent-runtime-auto-upgrade' "$CORE"
grep -Fq './files/usr/sbin/multica-log-hygiene ./wrt/files/usr/sbin/multica-log-hygiene' "$CORE"
grep -Fq './files/usr/sbin/multica-runtime-guard ./wrt/files/usr/sbin/multica-runtime-guard' "$CORE"
grep -Fq './files/etc/uci-defaults/93-logd-ring-size ./wrt/files/etc/uci-defaults/93-logd-ring-size' "$CORE"
grep -Fq './files/etc/uci-defaults/95-multica-maintenance-cron ./wrt/files/etc/uci-defaults/95-multica-maintenance-cron' "$CORE"
grep -Fq 'auto_runtime_upgrade' "$ROLE_CARD"
grep -Fq 'RE-SS-01 / RE-CS-02 / RE-CS-07' "$ROLE_CARD"

echo "agent runtime automatic upgrade guards passed"
