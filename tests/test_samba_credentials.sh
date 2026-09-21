#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$ROOT_DIR/Scripts/generate_samba_credentials.sh"
DEFAULT_USER="$ROOT_DIR/files/etc/uci-defaults/96-samba-default-user"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
ENV_INIT="$ROOT_DIR/Scripts/ci_init_environment.sh"

bash -n "$GENERATOR"
sh -n "$DEFAULT_USER"
grep -Eq 'aptx_retry install .* samba( | \\)$' "$ENV_INIT"
grep -Fq 'SAMBA_DEFAULT_USER:-smb' "$GENERATOR"
grep -Fq 'SAMBA_DEFAULT_PASSWORD:-}' "$GENERATOR"
grep -Fq 'SAMBA_MACHINE_SID:-S-1-5-21-' "$GENERATOR"
grep -Fq -- '--with-privatedir=/etc/samba' "$GENERATOR"
grep -Fq 'passdb backend = tdbsam' "$GENERATOR"
grep -Fq 'passdb.tdb secrets.tdb' "$GENERATOR"
grep -Fq 'pdbedit -s "$config" -L "$SAMBA_USER"' "$GENERATOR"
grep -Fq 'Scripts/generate_samba_credentials.sh" "$GITHUB_WORKSPACE/wrt"' "$CORE"
grep -Fq 'SAMBA_DEFAULT_PASSWORD:' "$CORE"
grep -Fq '96-samba-default-user' "$CORE"
grep -Fq '"./Config/$WRT_CONFIG.txt" ./Config/GENERAL.txt' "$CORE"
grep -Fq 'samba-default-credential' "$ROOT_DIR/Scripts/PrivateFirmwareGuard.sh"

if grep -Eq 'SAMBA_DEFAULT_PASSWORD:-[^}]+' "$GENERATOR"; then
	echo "Samba password must not have a source-code default" >&2
	exit 1
fi

if command -v smbpasswd >/dev/null 2>&1 && command -v pdbedit >/dev/null 2>&1 &&
	command -v net >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
	fixture="$(mktemp -d)"
	test_user_created=0
	cleanup_fixture() {
		[ "$test_user_created" -eq 0 ] || sudo userdel smb >/dev/null 2>&1 || true
		sudo rm -rf "$fixture"
	}
	trap cleanup_fixture EXIT
	mkdir -p "$fixture/feeds/packages/net/samba4/files"
	printf '%s\n' 'passdb backend = smbpasswd' >"$fixture/feeds/packages/net/samba4/files/smb.conf.template"
	printf '%s\n' 'CONFIGURE_ARGS += --with-privatedir=/etc/samba' >"$fixture/feeds/packages/net/samba4/Makefile"
	sudo -E env SAMBA_DEFAULT_PASSWORD='BuildTestOnly.1' bash "$GENERATOR" "$fixture"
	if ! getent passwd smb >/dev/null; then
		sudo useradd --system --no-create-home --home-dir /var --shell /usr/sbin/nologin smb
		test_user_created=1
	fi
	grep -Fxq 'passdb backend = tdbsam' "$fixture/feeds/packages/net/samba4/files/smb.conf.template"
	[ "$(sudo stat -c '%a' "$fixture/files/etc/samba/passdb.tdb")" = 600 ]
	[ "$(sudo stat -c '%a' "$fixture/files/etc/samba/secrets.tdb")" = 600 ]
	cat >"$fixture/runtime-smb.conf" <<EOF
[global]
netbios name = OPENWRT
workgroup = WORKGROUP
security = user
passdb backend = tdbsam
private dir = $fixture/files/etc/samba
state directory = $fixture/state
lock directory = $fixture/lock
pid directory = $fixture/run
ncalrpc dir = $fixture/ncalrpc
EOF
	mkdir -p "$fixture/state" "$fixture/lock" "$fixture/run" "$fixture/ncalrpc"
	sudo pdbedit -s "$fixture/runtime-smb.conf" -L smb | grep -Eq '^smb:'
	sudo net -s "$fixture/runtime-smb.conf" getlocalsid | grep -Fq 'S-1-5-21-3852847346-2771498014-1104378472'
fi
echo "Samba build-time credential guards passed"
