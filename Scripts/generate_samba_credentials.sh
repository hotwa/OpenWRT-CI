#!/usr/bin/env bash
# Generate a matched Samba tdbsam credential pair for the firmware overlay.
set -euo pipefail

WRT_ROOT="${1:-}"
SAMBA_USER="${SAMBA_DEFAULT_USER:-smb}"
SAMBA_PASSWORD="${SAMBA_DEFAULT_PASSWORD:-}"
# Stable standalone-server SID; passdb.tdb and secrets.tdb are still generated
# together on every build and are never stored in Git.
SAMBA_SID="${SAMBA_MACHINE_SID:-S-1-5-21-3852847346-2771498014-1104378472}"

[ -d "$WRT_ROOT" ] || { echo "usage: $0 <OpenWrt source root>" >&2; exit 2; }
[ -n "$SAMBA_PASSWORD" ] || {
	echo "ERROR: SAMBA_DEFAULT_PASSWORD must be supplied by an encrypted CI secret" >&2
	exit 1
}
for tool in smbpasswd pdbedit net getent useradd; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "ERROR: required Samba credential tool is missing: $tool" >&2
		exit 1
	}
done

template="$WRT_ROOT/feeds/packages/net/samba4/files/smb.conf.template"
[ -f "$template" ] || { echo "ERROR: Samba template not found: $template" >&2; exit 1; }
package_makefile="$WRT_ROOT/feeds/packages/net/samba4/Makefile"
[ -f "$package_makefile" ] || { echo "ERROR: Samba package Makefile not found: $package_makefile" >&2; exit 1; }
grep -Fq -- '--with-privatedir=/etc/samba' "$package_makefile" || {
	echo "ERROR: Samba runtime private dir is no longer /etc/samba; refusing to install mismatched databases" >&2
	exit 1
}
grep -Eq '^[[:space:]]*passdb backend[[:space:]]*=[[:space:]]*smbpasswd[[:space:]]*$' "$template" || {
	echo "ERROR: unexpected Samba passdb backend; refusing an unreviewed patch" >&2
	exit 1
}
sed -i -E 's|^([[:space:]]*passdb backend[[:space:]]*=[[:space:]]*)smbpasswd[[:space:]]*$|\1tdbsam|' "$template"
grep -Eq '^[[:space:]]*passdb backend[[:space:]]*=[[:space:]]*tdbsam[[:space:]]*$' "$template"

work_dir="$(mktemp -d)"
created_host_user=0
cleanup() {
	rm -rf -- "$work_dir"
	[ "$created_host_user" -eq 0 ] || userdel "$SAMBA_USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

if ! getent passwd "$SAMBA_USER" >/dev/null; then
	useradd --system --no-create-home --home-dir /var --shell /usr/sbin/nologin "$SAMBA_USER"
	created_host_user=1
fi

mkdir -p "$work_dir/private" "$work_dir/state" "$work_dir/lock" "$work_dir/run" "$work_dir/ncalrpc"
config="$work_dir/smb.conf"
cat >"$config" <<EOF
[global]
netbios name = OPENWRT
workgroup = WORKGROUP
security = user
passdb backend = tdbsam
private dir = $work_dir/private
state directory = $work_dir/state
lock directory = $work_dir/lock
pid directory = $work_dir/run
ncalrpc dir = $work_dir/ncalrpc
EOF

net -s "$config" setlocalsid "$SAMBA_SID"
printf '%s\n%s\n' "$SAMBA_PASSWORD" "$SAMBA_PASSWORD" | smbpasswd -c "$config" -a -s "$SAMBA_USER"
pdbedit -s "$config" -L "$SAMBA_USER" | grep -Eq "^${SAMBA_USER}:"
net -s "$config" getlocalsid | grep -Fq "$SAMBA_SID"

for database in passdb.tdb secrets.tdb; do
	[ -s "$work_dir/private/$database" ] || { echo "ERROR: Samba did not generate $database" >&2; exit 1; }
done

install -d -m 0755 "$WRT_ROOT/files/etc/samba"
install -m 0600 "$work_dir/private/passdb.tdb" "$WRT_ROOT/files/etc/samba/passdb.tdb"
install -m 0600 "$work_dir/private/secrets.tdb" "$WRT_ROOT/files/etc/samba/secrets.tdb"
echo "Generated paired Samba tdbsam databases for user $SAMBA_USER and SID $SAMBA_SID"
