#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/uci-defaults/95-clean-retired-openclaw-profile"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

[ -x "$SCRIPT" ] || { echo "missing retired OpenClaw profile migration"; exit 1; }
sh -n "$SCRIPT"

run_fixture() {
	local case_root="$1"
	shift
	env \
		RETIRED_OPENCLAW_PROFILE="$case_root/openclaw.sh" \
		RETIRED_OPENCLAW_HELPER="$case_root/openclaw-paths.sh" \
		RETIRED_OPENCLAW_SYSUPGRADE_CONF="$case_root/sysupgrade.conf" \
		RETIRED_OPENCLAW_SYSUPGRADE_ENTRY='/etc/profile.d/openclaw.sh' \
		"$@" \
		sh "$SCRIPT"
}

CASE_STALE="$TMP_ROOT/stale"
mkdir -p "$CASE_STALE"
printf '%s\n' '. /usr/libexec/openclaw-paths.sh' >"$CASE_STALE/openclaw.sh"
printf '%s\n' \
	'/etc/profile.d/openclaw.sh' \
	'/etc/config/openclaw' \
	'/etc/config/network' >"$CASE_STALE/sysupgrade.conf"
run_fixture "$CASE_STALE"
[ ! -e "$CASE_STALE/openclaw.sh" ] || { echo "stale profile survived"; exit 1; }
if grep -Fxq '/etc/profile.d/openclaw.sh' "$CASE_STALE/sysupgrade.conf"; then
	echo "stale profile is still retained by sysupgrade"
	exit 1
fi
grep -Fxq '/etc/config/openclaw' "$CASE_STALE/sysupgrade.conf" || {
	echo "migration removed user OpenClaw configuration"
	exit 1
}

CASE_REWRITE_FAILURE="$TMP_ROOT/rewrite-failure"
mkdir -p "$CASE_REWRITE_FAILURE"
printf '%s\n' '. /usr/libexec/openclaw-paths.sh' >"$CASE_REWRITE_FAILURE/openclaw.sh"
printf '%s\n' '/etc/profile.d/openclaw.sh' >"$CASE_REWRITE_FAILURE/sysupgrade.conf"
if run_fixture "$CASE_REWRITE_FAILURE" RETIRED_OPENCLAW_TEST_REWRITE_FAIL=1; then
	echo "retention-list write failure was ignored"
	exit 1
fi
[ -f "$CASE_REWRITE_FAILURE/openclaw.sh" ] || {
	echo "profile was removed before its retention entry was durable"
	exit 1
}
grep -Fxq '/etc/profile.d/openclaw.sh' "$CASE_REWRITE_FAILURE/sysupgrade.conf" || {
	echo "failed retention rewrite changed sysupgrade state"
	exit 1
}

CASE_ACTIVE="$TMP_ROOT/active"
mkdir -p "$CASE_ACTIVE"
printf '%s\n' '. /usr/libexec/openclaw-paths.sh' >"$CASE_ACTIVE/openclaw.sh"
: >"$CASE_ACTIVE/openclaw-paths.sh"
printf '%s\n' '/etc/profile.d/openclaw.sh' >"$CASE_ACTIVE/sysupgrade.conf"
run_fixture "$CASE_ACTIVE"
[ -f "$CASE_ACTIVE/openclaw.sh" ] || { echo "active profile was removed"; exit 1; }
grep -Fxq '/etc/profile.d/openclaw.sh' "$CASE_ACTIVE/sysupgrade.conf" || {
	echo "active profile retention was changed"
	exit 1
}

echo "retired OpenClaw profile migration tests passed"
