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
grep -Fq '7 3 * * * /usr/sbin/agent-runtime-auto-upgrade' "$CRON"
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
grep -Fq "AUTO_UPGRADE_OLD='0 3 * * * /usr/sbin/agent-runtime-auto-upgrade'" "$CRON_DEFAULTS"
grep -Fq "AUTO_UPGRADE_NEW='7 3 * * * /usr/sbin/agent-runtime-auto-upgrade'" "$CRON_DEFAULTS"

cron_fixture="$(mktemp)"
trap 'rm -f "$cron_fixture"' EXIT
printf '%s\n' \
	'0 3 * * * /usr/sbin/agent-runtime-auto-upgrade' \
	'1 2 * * * /usr/bin/unrelated' >"$cron_fixture"
CRONTAB_FILE="$cron_fixture" sh "$CRON_DEFAULTS"
grep -Fqx '7 3 * * * /usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture"
grep -Fqx '1 2 * * * /usr/bin/unrelated' "$cron_fixture"
[ "$(grep -Fc '/usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture")" -eq 1 ]
CRONTAB_FILE="$cron_fixture" sh "$CRON_DEFAULTS"
[ "$(grep -Fc '/usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture")" -eq 1 ]

printf '%s\n' '11 4 * * * /usr/sbin/agent-runtime-auto-upgrade' >"$cron_fixture"
CRONTAB_FILE="$cron_fixture" sh "$CRON_DEFAULTS"
grep -Fqx '11 4 * * * /usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture"
[ "$(grep -Fc '/usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture")" -eq 1 ]
grep -Fq 'LOCK_DIR="${LOCK_DIR:-/var/run/multica-maintenance.lock}"' "$SCRIPT"
grep -Fq 'LOCK_DIR="/var/run/multica-maintenance.lock"' "$LOG_HYGIENE"
grep -Fq 'LOCK_DIR="/var/run/multica-maintenance.lock"' "$RUNTIME_GUARD"
if grep -Fq 'config.json' "$LOG_HYGIENE"; then
	echo "log hygiene helper must not reference Multica config.json"
	exit 1
fi
grep -Fq 'check --json' "$SCRIPT"
grep -Fq 'upgrade --json' "$SCRIPT"
grep -Fq 'an Agent task is active' "$SCRIPT"

runtime_fixture="$(mktemp -d)"
trap 'rm -rf "$runtime_fixture" "$cron_fixture"' EXIT
mkdir -p "$runtime_fixture/data/multica/logs" "$runtime_fixture/lock" "$runtime_fixture/bin"
cat >"$runtime_fixture/bin/uci" <<'EOF'
#!/bin/sh
printf '1\n'
EOF
cat >"$runtime_fixture/agent-runtime" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$AGENT_RUNTIME_TEST_CALLS"
printf '%s\n' '{"ok":true,"code":"no_update"}'
EOF
chmod +x "$runtime_fixture/agent-runtime" "$runtime_fixture/bin/uci"
export AGENT_RUNTIME_TEST_CALLS="$runtime_fixture/calls"
LOCK_DIR="$runtime_fixture/lock" \
	DATA_ROOT="$runtime_fixture/data" \
	DATA_DIR="$runtime_fixture/data/multica" \
	RUNTIME_BIN="$runtime_fixture/agent-runtime" \
	PATH="$runtime_fixture/bin:$PATH" \
	sh "$SCRIPT" >"$runtime_fixture/locked.out"
grep -Fq 'another Multica maintenance task is already running' "$runtime_fixture/locked.out" || {
	echo "lock-contention message was not printed" >&2
	cat "$runtime_fixture/locked.out" >&2
	exit 1
}
[ ! -e "$AGENT_RUNTIME_TEST_CALLS" ]

rmdir "$runtime_fixture/lock"
LOCK_DIR="$runtime_fixture/lock" \
	DATA_ROOT="$runtime_fixture/data" \
	DATA_DIR="$runtime_fixture/data/multica" \
	RUNTIME_BIN="$runtime_fixture/agent-runtime" \
	PATH="$runtime_fixture/bin:$PATH" \
	sh "$SCRIPT" >"$runtime_fixture/unlocked.out"
grep -Fq 'check: {"ok":true,"code":"no_update"}' "$runtime_fixture/unlocked.out"
[ "$(wc -l <"$AGENT_RUNTIME_TEST_CALLS")" -eq 1 ]
grep -Fq './files/etc/crontabs/root ./wrt/files/etc/crontabs/root' "$CORE"
grep -Fq './files/usr/sbin/agent-runtime-auto-upgrade ./wrt/files/usr/sbin/agent-runtime-auto-upgrade' "$CORE"
grep -Fq './files/usr/sbin/multica-log-hygiene ./wrt/files/usr/sbin/multica-log-hygiene' "$CORE"
grep -Fq './files/usr/sbin/multica-runtime-guard ./wrt/files/usr/sbin/multica-runtime-guard' "$CORE"
grep -Fq './files/etc/uci-defaults/93-logd-ring-size ./wrt/files/etc/uci-defaults/93-logd-ring-size' "$CORE"
grep -Fq './files/etc/uci-defaults/95-multica-maintenance-cron ./wrt/files/etc/uci-defaults/95-multica-maintenance-cron' "$CORE"
grep -Fq 'auto_runtime_upgrade' "$ROLE_CARD"
grep -Fq 'RE-SS-01 / RE-CS-02 / RE-CS-07' "$ROLE_CARD"

echo "agent runtime automatic upgrade guards passed"
