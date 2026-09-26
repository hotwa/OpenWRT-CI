#!/usr/bin/env bash
# CNB-only adapter for the existing OpenWrt host dependency installer.
# Do not change the GitHub Actions environment bootstrap to work around a
# CNB-specific /etc/localtime bind mount.
set -euo pipefail

. /etc/os-release
[ "${VERSION_CODENAME:-}" = bookworm ] || {
  echo 'ERROR: CNB builder must use Debian bookworm' >&2
  exit 1
}
[ "$(id -u)" -eq 0 ] || {
  echo 'ERROR: dependency bootstrap requires root inside the disposable builder container' >&2
  exit 1
}
# tzdata.postinst attempts to replace /etc/localtime. CNB bind-mounts that path,
# so an image WITHOUT preinstalled tzdata becomes a broken dpkg transaction.
dpkg-query -W -f='${Status}' tzdata 2>/dev/null | grep -qx 'install ok installed' || {
  echo 'ERROR: base builder image must already contain configured tzdata' >&2
  exit 1
}

# init_build_environment.sh intentionally uses -t bookworm-backports for GCC
# and full-upgrade. The official Python image does not necessarily enable it.
if ! grep -rhE '^[[:space:]]*deb[[:space:]].*bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
  printf '%s\n' 'deb http://deb.debian.org/debian bookworm-backports main' \
    > /etc/apt/sources.list.d/cnb-bookworm-backports.list
fi
export DEBIAN_FRONTEND=noninteractive
unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN
# Keep the same 60-minute hard bound as WRT-CORE and fail on any missing tool.
timeout --kill-after=30 3600 bash "$(dirname "$0")/ci_init_environment.sh"
python3 "$(dirname "$0")/cnb_re_profile_preflight.py"
for tool in git make smbpasswd jq dos2unix; do
  command -v "$tool" >/dev/null || { echo "ERROR: builder tool unavailable: $tool" >&2; exit 1; }
done
echo 'CNB OpenWrt dependency bootstrap passed; no firmware or device operation'
