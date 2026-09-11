#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT_DIR/files/usr/sbin/nikki-dns-failopen"
INIT="$ROOT_DIR/files/etc/init.d/nikki-dns-failopen"
CONFIG="$ROOT_DIR/files/etc/config/nikki-dns-failopen"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/99-enable-nikki-dns-failopen"
DOC="$ROOT_DIR/docs/nikki-dns-failopen.md"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -x "$GUARD" ] || { echo "missing executable nikki DNS fail-open guard"; exit 1; }
[ -x "$INIT" ] || { echo "missing executable nikki DNS fail-open init script"; exit 1; }
[ -f "$CONFIG" ] || { echo "missing nikki DNS fail-open UCI config"; exit 1; }
[ -x "$DEFAULTS" ] || { echo "missing executable nikki DNS fail-open defaults script"; exit 1; }
[ -f "$DOC" ] || { echo "missing nikki DNS fail-open documentation"; exit 1; }

sh -n "$GUARD"
sh -n "$INIT"
sh -n "$DEFAULTS"

grep -Fq 'CONFIG_PACKAGE_bind-nslookup=y' "$ROOT_DIR/Config/GENERAL.txt"
grep -Fq 'CONFIG_PACKAGE_flock=y' "$ROOT_DIR/Config/GENERAL.txt"
grep -Fq 'START=99' "$INIT"
grep -Fq 'procd_set_param respawn 3600 5 2' "$INIT"
grep -Fq '/etc/init.d/nikki-dns-failopen enable' "$DEFAULTS"
grep -Fq '[ -x /etc/init.d/nikki ] || exit 0' "$DEFAULTS"
[[ "S99nikki" < "S99nikki-dns-failopen" ]] || { echo "Nikki must sort before its DNS fail-open guard"; exit 1; }

for path in \
	'files/etc/config/nikki-dns-failopen' \
	'files/etc/init.d/nikki-dns-failopen' \
	'files/etc/uci-defaults/99-enable-nikki-dns-failopen' \
	'files/usr/sbin/nikki-dns-failopen'; do
	grep -Fq "./$path ./wrt/$path" "$CORE" || {
		echo "WRT-CORE does not inject $path into every firmware overlay"
		exit 1
	}
done
grep -Fq "path '*/luci-app-nikki/root/etc/init.d/nikki'" "$CORE"
grep -Fq 'Nikki init START must remain 99 for fail-open startup ordering' "$CORE"
grep -Fq 'Nikki package init is absent for this target; skipping its startup-order assertion' "$CORE"

for setting in \
	"option enabled '1'" \
	"option check_interval '60'" \
	"option failure_threshold '2'" \
	"option restart_cooldown '600'" \
	"option settle_wait '10'" \
	"option max_restarts '3'" \
	"option prebase_max '2'" \
	"option probe_suffix 'example.com'"; do
	grep -Fq "$setting" "$CONFIG"
done

for forbidden in 'uci set' 'uci add' 'uci delete' 'uci commit' 'ip route add' 'ip route del' 'reboot' 'dnsmasq restart' 'tailscale restart'; do
	if grep -Fq "$forbidden" "$GUARD"; then
		echo "guard contains forbidden runtime mutation: $forbidden"
		exit 1
	fi
done
grep -Fq '"$NIKKI_INIT" restart' "$GUARD"
grep -Fq 'nft delete table inet "$TABLE"' "$GUARD"
grep -Fq 'exec 9>>"$LOCK_FILE"' "$GUARD"
grep -Fq '*Usage:*)' "$GUARD"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
MOCK_BIN="$WORK_DIR/bin"
mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/uci" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$MOCK_BIN/ip" <<'EOF'
#!/bin/sh
[ "${NDF_TEST_WAN_UP:-1}" = '1' ] || exit 0
[ "$*" = 'route show default' ] && echo 'default via 192.0.2.1 dev wan'
EOF
cat >"$MOCK_BIN/pgrep" <<'EOF'
#!/bin/sh
[ "${NDF_TEST_DNSMASQ_UP:-1}" = '1' ]
EOF
cat >"$MOCK_BIN/nft" <<'EOF'
#!/bin/sh
case "$1 $2 $3 $4" in
	'list table inet '*) [ -f "$NDF_TEST_TABLE_FILE" ] ;;
	'delete table inet '*)
		printf '%s\n' "nft-delete:$4" >>"$NDF_TEST_ACTIONS"
		rm -f "$NDF_TEST_TABLE_FILE"
		;;
	*) exit 1 ;;
esac
EOF
cat >"$MOCK_BIN/nslookup" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$NDF_TEST_NSLOOKUP_CALLS"
if [ -n "${NDF_TEST_RESTART_HEALS_FILE:-}" ] && [ -f "$NDF_TEST_RESTART_HEALS_FILE" ]; then
	printf '%s\n' 'Address: 198.18.0.42'
	exit 0
fi
case "${NDF_TEST_DNS_MODE:-dead}" in
	healthy) printf '%s\n' 'Address: 198.18.0.42' ;;
	usage-fallback)
		case " $* " in
			*' -port='*) printf '%s\n' 'Usage: nslookup [options]' >&2; exit 1 ;;
			*) printf '%s\n' 'Address: 198.18.0.43' ;;
		esac
		;;
	*) printf '%s\n' 'no servers could be reached' >&2; exit 1 ;;
esac
EOF
cat >"$MOCK_BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$NDF_TEST_LOG"
EOF
cat >"$MOCK_BIN/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$MOCK_BIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$MOCK_BIN/date" <<'EOF'
#!/bin/sh
printf '%s\n' "${NDF_TEST_NOW:-1000}"
EOF
cat >"$WORK_DIR/nikki-init" <<'EOF'
#!/bin/sh
printf '%s\n' "nikki-$1" >>"$NDF_TEST_ACTIONS"
[ -z "${NDF_TEST_RESTART_HEALS_FILE:-}" ] || : >"$NDF_TEST_RESTART_HEALS_FILE"
EOF
chmod 0755 "$MOCK_BIN"/* "$WORK_DIR/nikki-init"

export NDF_PATH="$MOCK_BIN:$PATH"
export NDF_TABLE=ndf_test
export NDF_NIKKI_INIT="$WORK_DIR/nikki-init"
export NDF_STATE_FILE="$WORK_DIR/state"
export NDF_MARKER="$WORK_DIR/active"
export NDF_LOCK_FILE="$WORK_DIR/lock"
export NDF_TEST_TABLE_FILE="$WORK_DIR/table-present"
export NDF_TEST_ACTIONS="$WORK_DIR/actions"
export NDF_TEST_NSLOOKUP_CALLS="$WORK_DIR/nslookup-calls"
export NDF_TEST_LOG="$WORK_DIR/log"
: >"$NDF_TEST_ACTIONS"; : >"$NDF_TEST_NSLOOKUP_CALLS"; : >"$NDF_TEST_LOG"

# No Nikki table is a healthy direct path and must never trigger a write action.
rm -f "$NDF_TEST_TABLE_FILE"
"$GUARD" --once
[ ! -s "$NDF_TEST_ACTIONS" ]

# A present table with working mihomo DNS is healthy.
: >"$NDF_TEST_TABLE_FILE"
export NDF_TEST_DNS_MODE=healthy
"$GUARD" --once
[ ! -s "$NDF_TEST_ACTIONS" ]
grep -Fq 'BASELINE=1' "$NDF_STATE_FILE"

# Test suffix overrides survive config loading and keep the name cache-busting.
: >"$NDF_TEST_NSLOOKUP_CALLS"
export NDF_PROBE_SUFFIX=probe.invalid
"$GUARD" --status >/dev/null
grep -Eq 'probe-[0-9]+-[0-9]+\.probe\.invalid' "$NDF_TEST_NSLOOKUP_CALLS"
unset NDF_PROBE_SUFFIX

# A dead explicit port must not fall back to port 53 unless nslookup prints Usage.
: >"$NDF_TEST_NSLOOKUP_CALLS"
export NDF_TEST_DNS_MODE=dead
status_output="$("$GUARD" --status)"
grep -Fq 'health=degraded(mihomo DNS unresponsive)' <<<"$status_output"
[ "$(wc -l <"$NDF_TEST_NSLOOKUP_CALLS")" -eq 1 ]

# An actual unsupported-option Usage result takes exactly one semantic fallback.
: >"$NDF_TEST_NSLOOKUP_CALLS"
export NDF_TEST_DNS_MODE=usage-fallback
status_output="$("$GUARD" --status)"
grep -Fq 'health=healthy(via mihomo)' <<<"$status_output"
[ "$(wc -l <"$NDF_TEST_NSLOOKUP_CALLS")" -eq 2 ]

# Boot races are observation-only: missing WAN/dnsmasq and pre-baseline failures
# cannot restart Nikki or remove its table.
export NDF_TEST_DNS_MODE=dead NDF_TEST_WAN_UP=0
printf 'FAIL=1\nLAST_RESTART=0\nRESTARTS=0\nBASELINE=1\nPREBASE=0\nFAILOPEN=0\n' >"$NDF_STATE_FILE"
: >"$NDF_TEST_TABLE_FILE"; : >"$NDF_TEST_ACTIONS"
"$GUARD" --once
[ -f "$NDF_TEST_TABLE_FILE" ]
[ ! -s "$NDF_TEST_ACTIONS" ]
grep -Fq 'FAIL=1' "$NDF_STATE_FILE"
unset NDF_TEST_WAN_UP

export NDF_TEST_DNSMASQ_UP=0
"$GUARD" --once
[ -f "$NDF_TEST_TABLE_FILE" ]
[ ! -s "$NDF_TEST_ACTIONS" ]
unset NDF_TEST_DNSMASQ_UP

printf 'FAIL=0\nLAST_RESTART=0\nRESTARTS=0\nBASELINE=0\nPREBASE=0\nFAILOPEN=0\n' >"$NDF_STATE_FILE"
: >"$NDF_TEST_ACTIONS"
"$GUARD" --once
"$GUARD" --once
[ -f "$NDF_TEST_TABLE_FILE" ]
[ ! -s "$NDF_TEST_ACTIONS" ]
grep -Fq 'BASELINE=1' "$NDF_STATE_FILE"
grep -Fq 'PREBASE=2' "$NDF_STATE_FILE"

# Two confirmed failures: restart first, then delete only the test table.
export NDF_TEST_DNS_MODE=dead
unset NDF_TEST_RESTART_HEALS_FILE || true
printf 'FAIL=0\nLAST_RESTART=0\nRESTARTS=0\nBASELINE=1\nPREBASE=0\nFAILOPEN=0\n' >"$NDF_STATE_FILE"
: >"$NDF_TEST_TABLE_FILE"; : >"$NDF_TEST_ACTIONS"
"$GUARD" --once
grep -Fq 'FAIL=1' "$NDF_STATE_FILE"
[ -f "$NDF_TEST_TABLE_FILE" ]
"$GUARD" --once
[ ! -f "$NDF_TEST_TABLE_FILE" ]
[ -f "$NDF_MARKER" ]
grep -Fq 'FAILOPEN=1' "$NDF_STATE_FILE"
[ "$(sed -n '1p' "$NDF_TEST_ACTIONS")" = 'nikki-restart' ]
[ "$(sed -n '2p' "$NDF_TEST_ACTIONS")" = 'nft-delete:ndf_test' ]

# If restart restores DNS, do not delete the table and reset the restart budget.
export NDF_TEST_RESTART_HEALS_FILE="$WORK_DIR/restart-healed"
rm -f "$NDF_TEST_RESTART_HEALS_FILE" "$NDF_MARKER"
printf 'FAIL=1\nLAST_RESTART=0\nRESTARTS=0\nBASELINE=1\nPREBASE=0\nFAILOPEN=0\n' >"$NDF_STATE_FILE"
: >"$NDF_TEST_TABLE_FILE"; : >"$NDF_TEST_ACTIONS"
"$GUARD" --once
[ -f "$NDF_TEST_TABLE_FILE" ]
grep -Fq 'nikki-restart' "$NDF_TEST_ACTIONS"
! grep -Fq 'nft-delete' "$NDF_TEST_ACTIONS"
grep -Fq 'RESTARTS=0' "$NDF_STATE_FILE"
unset NDF_TEST_RESTART_HEALS_FILE

# Cooldown defers the restart; an exhausted budget goes directly to fail-open.
export NDF_TEST_DNS_MODE=dead NDF_TEST_NOW=1000
printf 'FAIL=1\nLAST_RESTART=1000\nRESTARTS=1\nBASELINE=1\nPREBASE=0\nFAILOPEN=0\n' >"$NDF_STATE_FILE"
: >"$NDF_TEST_TABLE_FILE"; : >"$NDF_TEST_ACTIONS"; : >"$NDF_TEST_LOG"
"$GUARD" --once
[ -f "$NDF_TEST_TABLE_FILE" ]
[ ! -s "$NDF_TEST_ACTIONS" ]
grep -Fq 'restart cooldown 600s remaining' "$NDF_TEST_LOG"

printf 'FAIL=1\nLAST_RESTART=0\nRESTARTS=3\nBASELINE=1\nPREBASE=0\nFAILOPEN=0\n' >"$NDF_STATE_FILE"
: >"$NDF_TEST_TABLE_FILE"; : >"$NDF_TEST_ACTIONS"
"$GUARD" --once
[ ! -f "$NDF_TEST_TABLE_FILE" ]
! grep -Fq 'nikki-restart' "$NDF_TEST_ACTIONS"
grep -Fq 'nft-delete:ndf_test' "$NDF_TEST_ACTIONS"

echo "nikki DNS fail-open guards passed"
