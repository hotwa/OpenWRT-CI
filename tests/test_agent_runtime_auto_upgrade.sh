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
CRON_RECONCILER="$ROOT_DIR/files/usr/sbin/multica-maintenance-cron-reconcile"

[ -x "$SCRIPT" ] || { echo "auto-upgrade wrapper is missing or not executable"; exit 1; }
[ -f "$CRON" ] || { echo "nightly runtime cron is missing"; exit 1; }
sh -n "$SCRIPT"
grep -Fq "option auto_runtime_upgrade '1'" "$CONFIG"
grep -Fq '7 3 * * * /usr/sbin/agent-runtime-auto-upgrade' "$CRON"
grep -Fq '53 2 * * * /usr/sbin/agent-runtime-health-check' "$CRON"
grep -Fq '*/5 * * * * /usr/sbin/multica-runtime-guard #multica runtime guard' "$CRON"
grep -Fq '*/30 * * * * /usr/sbin/multica-log-hygiene #multica log hygiene' "$CRON"
[ -x "$LOG_HYGIENE" ] || { echo "multica log hygiene helper is missing or not executable"; exit 1; }
sh -n "$LOG_HYGIENE"
sh -n "$RUNTIME_GUARD"
[ -x "$LOGD_DEFAULTS" ] || { echo "logd ring-size defaults are missing or not executable"; exit 1; }
[ -x "$CRON_DEFAULTS" ] || { echo "Multica cron defaults are missing or not executable"; exit 1; }
[ -f "$CRON_RECONCILER" ] || { echo "Multica cron reconciler is missing"; exit 1; }
sh -n "$LOGD_DEFAULTS"
sh -n "$CRON_DEFAULTS"
sh -n "$CRON_RECONCILER"
grep -Fq "system.@system[0].log_size=256" "$LOGD_DEFAULTS"
grep -Fq 'multica-maintenance-cron-reconcile' "$CRON_DEFAULTS"
grep -Fq '#multica runtime guard' "$CRON_RECONCILER"
grep -Fq '#multica log hygiene' "$CRON_RECONCILER"
grep -Fq "RUNTIME_VERIFY_COMMAND='/usr/sbin/agent-runtime-health-check'" "$CRON_RECONCILER"
grep -Fq "RUNTIME_VERIFY_NEW='53 2 * * * /usr/sbin/agent-runtime-health-check'" "$CRON_RECONCILER"
grep -Fq "AUTO_UPGRADE_COMMAND='/usr/sbin/agent-runtime-auto-upgrade'" "$CRON_RECONCILER"
grep -Fq "AUTO_UPGRADE_NEW='7 3 * * * /usr/sbin/agent-runtime-auto-upgrade'" "$CRON_RECONCILER"

cron_fixture="$(mktemp)"
cron_failure_fixture="$(mktemp -d)"
trap 'rm -rf "$cron_fixture" "$cron_failure_fixture"' EXIT
printf '%s\n' \
	'0 3 * * * /usr/sbin/agent-runtime-auto-upgrade' \
	'7 3 * * * /usr/sbin/agent-runtime-auto-upgrade' \
	'7 3 * * * /usr/sbin/agent-runtime-auto-upgrade' \
	'10 3 * * * /usr/sbin/agent-runtime-health-check' \
	'53 2 * * * /usr/sbin/agent-runtime-health-check' \
	'11 4 * * * /usr/sbin/agent-runtime-auto-upgrade' \
	'# 0 3 * * * /usr/sbin/agent-runtime-auto-upgrade (historical note)' \
	'1 2 * * * /usr/bin/unrelated' >"$cron_fixture"
CRONTAB_FILE="$cron_fixture" sh "$CRON_RECONCILER"
grep -Fqx '7 3 * * * /usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture"
grep -Fqx '53 2 * * * /usr/sbin/agent-runtime-health-check' "$cron_fixture"
grep -Fqx '1 2 * * * /usr/bin/unrelated' "$cron_fixture"
grep -Fqx '# 0 3 * * * /usr/sbin/agent-runtime-auto-upgrade (historical note)' "$cron_fixture"
[ "$(awk '$1 !~ /^#/ && $6 == "/usr/sbin/agent-runtime-auto-upgrade" { count++ } END { print count + 0 }' "$cron_fixture")" -eq 1 ]
[ "$(awk '$1 !~ /^#/ && $6 == "/usr/sbin/agent-runtime-health-check" { count++ } END { print count + 0 }' "$cron_fixture")" -eq 1 ]
CRONTAB_FILE="$cron_fixture" sh "$CRON_RECONCILER"
[ "$(awk '$1 !~ /^#/ && $6 == "/usr/sbin/agent-runtime-auto-upgrade" { count++ } END { print count + 0 }' "$cron_fixture")" -eq 1 ]
[ "$(awk '$1 !~ /^#/ && $6 == "/usr/sbin/agent-runtime-health-check" { count++ } END { print count + 0 }' "$cron_fixture")" -eq 1 ]

printf '%s\n' '11 4 * * * /usr/sbin/agent-runtime-auto-upgrade' >"$cron_fixture"
CRONTAB_FILE="$cron_fixture" sh "$CRON_RECONCILER"
grep -Fqx '7 3 * * * /usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture"
grep -Fqx '53 2 * * * /usr/sbin/agent-runtime-health-check' "$cron_fixture"
if grep -Fqx '11 4 * * * /usr/sbin/agent-runtime-auto-upgrade' "$cron_fixture"; then
	echo "custom auto-upgrade schedule was not normalized" >&2
	exit 1
fi
if grep -Fqx '10 3 * * * /usr/sbin/agent-runtime-health-check' "$cron_fixture"; then
	echo "custom runtime verification schedule was not normalized" >&2
	exit 1
fi

# A publication failure must leave the original file intact and return
# nonzero so OpenWrt retains this uci-defaults script for a later retry.
mkdir -p "$cron_failure_fixture/bin"
printf '%s\n' \
	'0 3 * * * /usr/sbin/agent-runtime-auto-upgrade' \
	'2 4 * * * /usr/bin/unrelated' >"$cron_failure_fixture/root"
cp "$cron_failure_fixture/root" "$cron_failure_fixture/original"
cat >"$cron_failure_fixture/bin/mv" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$cron_failure_fixture/bin/mv"
if PATH="$cron_failure_fixture/bin:$PATH" \
	CRONTAB_FILE="$cron_failure_fixture/root" \
	sh "$CRON_RECONCILER" >/dev/null 2>&1; then
	echo "cron defaults succeeded despite an injected publish failure" >&2
	exit 1
fi
cmp -s "$cron_failure_fixture/original" "$cron_failure_fixture/root" || {
	echo "cron defaults changed the destination before atomic publication" >&2
	exit 1
}
grep -Fq 'AUTO_UPGRADE_LOCK_FILE="${AUTO_UPGRADE_LOCK_FILE:-/var/lock/agent-runtime-auto-upgrade.lock}"' "$SCRIPT"
grep -Fq 'MAINTENANCE_LOCK_FILE="${MAINTENANCE_LOCK_FILE:-/var/lock/multica-maintenance.lock}"' "$SCRIPT"
grep -Fq 'INVOCATION_LOCK_FILE="${INVOCATION_LOCK_FILE:-/var/lock/multica-log-hygiene.lock}"' "$LOG_HYGIENE"
grep -Fq 'GUARD_LOCK_FILE="${GUARD_LOCK_FILE:-/var/lock/multica-runtime-guard.lock}"' "$RUNTIME_GUARD"
grep -Fq 'attempt" -lt 12' "$SCRIPT"
if grep -Fq 'another Multica maintenance task is already running' "$SCRIPT"; then
	echo "a read-only runtime check must not contend with the mutation lock" >&2
	exit 1
fi
if grep -Fq 'config.json' "$LOG_HYGIENE"; then
	echo "log hygiene helper must not reference Multica config.json"
	exit 1
fi
grep -Fq 'check --json' "$SCRIPT"
grep -Fq 'upgrade --json' "$SCRIPT"
grep -Fq 'an Agent task is active' "$SCRIPT"

runtime_fixture="$(mktemp -d)"
trap 'rm -rf "$runtime_fixture" "$cron_fixture" "$cron_failure_fixture"' EXIT
mkdir -p "$runtime_fixture/data/multica/logs" "$runtime_fixture/bin"
cat >"$runtime_fixture/bin/uci" <<'EOF'
#!/bin/sh
printf '1\n'
EOF
cat >"$runtime_fixture/bin/jsonfilter" <<'EOF'
#!/bin/sh
payload="${2:-}"
printf '%s\n' "$payload" | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
EOF
cat >"$runtime_fixture/agent-runtime" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$AGENT_RUNTIME_TEST_CALLS"
case "$1" in
  check)
    if [ -n "${AGENT_RUNTIME_CHECK_JSON:-}" ]; then
      printf '%s\n' "$AGENT_RUNTIME_CHECK_JSON"
    else
      printf '%s\n' '{"ok":true,"code":"no_update"}'
    fi
    ;;
  upgrade) printf '%s\n' '{"ok":true,"code":"ok"}' ;;
esac
EOF
chmod +x "$runtime_fixture/agent-runtime" "$runtime_fixture/bin/uci" "$runtime_fixture/bin/jsonfilter"
export AGENT_RUNTIME_TEST_CALLS="$runtime_fixture/calls"
AUTO_UPGRADE_LOCK_FILE="$runtime_fixture/auto-upgrade.lock" \
	MAINTENANCE_LOCK_FILE="$runtime_fixture/maintenance.lock" \
	DATA_ROOT="$runtime_fixture/data" \
	DATA_DIR="$runtime_fixture/data/multica" \
	RUNTIME_BIN="$runtime_fixture/agent-runtime" \
	PATH="$runtime_fixture/bin:$PATH" \
	sh "$SCRIPT" >"$runtime_fixture/unlocked.out"
grep -Fq 'check: {"ok":true,"code":"no_update"}' "$runtime_fixture/unlocked.out"
[ "$(wc -l <"$AGENT_RUNTIME_TEST_CALLS")" -eq 1 ]

flock -n "$runtime_fixture/held-auto-upgrade.lock" -c 'sleep 2' &
lock_holder=$!
sleep 0.1
AUTO_UPGRADE_LOCK_FILE="$runtime_fixture/held-auto-upgrade.lock" \
	DATA_ROOT="$runtime_fixture/data" \
	DATA_DIR="$runtime_fixture/data/multica" \
	RUNTIME_BIN="$runtime_fixture/agent-runtime" \
	PATH="$runtime_fixture/bin:$PATH" \
	sh "$SCRIPT" >"$runtime_fixture/locked.out"
grep -Fq 'another automatic runtime-upgrade check is already running' "$runtime_fixture/locked.out"
wait "$lock_holder"

AGENT_RUNTIME_CHECK_JSON='{"ok":true,"code":"ok"}' \
	AUTO_UPGRADE_LOCK_FILE="$runtime_fixture/upgrade.lock" \
	MAINTENANCE_LOCK_FILE="$runtime_fixture/maintenance.lock" \
	DATA_ROOT="$runtime_fixture/data" DATA_DIR="$runtime_fixture/data/multica" \
	RUNTIME_BIN="$runtime_fixture/agent-runtime" PATH="$runtime_fixture/bin:$PATH" \
	sh "$SCRIPT" >"$runtime_fixture/upgrade.out"
grep -Fq 'upgrade: {"ok":true,"code":"ok"}' "$runtime_fixture/upgrade.out"
[ "$(tail -n 1 "$AGENT_RUNTIME_TEST_CALLS")" = upgrade ]
grep -Fq './files/etc/crontabs/root ./wrt/files/etc/crontabs/root' "$CORE"
grep -Fq './files/usr/sbin/agent-runtime-auto-upgrade ./wrt/files/usr/sbin/agent-runtime-auto-upgrade' "$CORE"
grep -Fq './files/usr/sbin/agent-runtime-health-check ./wrt/files/usr/sbin/agent-runtime-health-check' "$CORE"
grep -Fq './files/usr/sbin/multica-maintenance-cron-reconcile ./wrt/files/usr/sbin/multica-maintenance-cron-reconcile' "$CORE"
grep -Fq './files/usr/sbin/multica-log-hygiene ./wrt/files/usr/sbin/multica-log-hygiene' "$CORE"
grep -Fq './files/usr/sbin/multica-runtime-guard ./wrt/files/usr/sbin/multica-runtime-guard' "$CORE"
grep -Fq './files/etc/uci-defaults/93-logd-ring-size ./wrt/files/etc/uci-defaults/93-logd-ring-size' "$CORE"
grep -Fq './files/etc/uci-defaults/95-multica-maintenance-cron ./wrt/files/etc/uci-defaults/95-multica-maintenance-cron' "$CORE"
grep -Fq 'auto_runtime_upgrade' "$ROLE_CARD"
grep -Fq 'RE-SS-01 / RE-CS-02 / RE-CS-07' "$ROLE_CARD"
grep -Fq '每日 03:07' "$ROLE_CARD"
if grep -Fq '每日 03:00' "$ROLE_CARD"; then
	echo "role card still documents the obsolete 03:00 runtime schedule" >&2
	exit 1
fi
if grep -Eq '当前维护基线为 `[0-9a-fA-F]{7,40}`' "$ROLE_CARD"; then
	echo "role card hard-codes a stale firmware maintenance baseline" >&2
	exit 1
fi

echo "agent runtime automatic upgrade guards passed"
