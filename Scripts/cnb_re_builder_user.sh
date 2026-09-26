#!/usr/bin/env bash
# Run the OpenWrt build unprivileged, preserving the GitHub sudo-only Samba step.
set -euo pipefail
set +x
[ "$(id -u)" -eq 0 ] || { echo 'ERROR: builder user setup requires container root' >&2; exit 1; }
workspace="$(cd "$(dirname "$0")/.." && pwd -P)"
[ -f "$workspace/.github/workflows/WRT-CORE.yml" ] || {
  echo 'ERROR: expected private build checkout is absent' >&2; exit 1;
}
[ ! -e "$workspace/wrt" ] || { echo 'ERROR: source directory already exists before build' >&2; exit 1; }
# GitHub installs bc before the main bootstrap; its host step also has sudo.
if ! command -v sudo >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo bc
fi
command -v runuser >/dev/null || { echo 'ERROR: runuser unavailable' >&2; exit 1; }
if ! id cnbbuild >/dev/null 2>&1; then
  useradd --create-home --uid 1001 --shell /bin/bash cnbbuild
fi
# This container is disposable. Only the reviewed credential database generator
# needs root, and it receives the password from the existing secret import.
sudoers=/etc/sudoers.d/cnb-openwrt-samba
printf 'cnbbuild ALL=(root) NOPASSWD:SETENV: %s/Scripts/generate_samba_credentials.sh\n' "$workspace" > "$sudoers"
chmod 0440 "$sudoers"
visudo -cf "$sudoers" >/dev/null
chown -R cnbbuild:cnbbuild "$workspace"
install -d -m 0755 -o cnbbuild -g cnbbuild /home/cnbbuild/.cache
printf '%s\n' 'CNB non-root firmware builder prepared; only the Samba generator is sudo-allowed'
