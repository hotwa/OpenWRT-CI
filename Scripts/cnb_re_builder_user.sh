#!/usr/bin/env bash
# Run OpenWrt as a non-root user with GitHub-runner-equivalent sudo in this
# disposable build-only container. CNB CD/release credentials are not imported.
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
# The GitHub runner can use passwordless sudo (repository smoke fixtures
# exercise `sudo -E python3` and `sudo runuser`). Apply parity only inside this
# ephemeral CNB build container, never to the host or release/device tasks.
sudoers=/etc/sudoers.d/cnb-openwrt-build
printf '%s\n' 'cnbbuild ALL=(ALL) NOPASSWD:SETENV: ALL' > "$sudoers"
chmod 0440 "$sudoers"
visudo -cf "$sudoers" >/dev/null
chown -R cnbbuild:cnbbuild "$workspace"
install -d -m 0755 -o cnbbuild -g cnbbuild /home/cnbbuild/.cache
printf '%s\n' 'CNB non-root firmware builder prepared with GitHub-like container-local sudo'
