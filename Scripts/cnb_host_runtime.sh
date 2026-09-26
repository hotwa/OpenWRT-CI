#!/usr/bin/env bash
# Official host Go/Node downloads, pinned to the GitHub setup actions' versions.
#   Go   : https://go.dev/dl/?mode=json&include=all  (per-file sha256 field)
#   Node : https://nodejs.org/dist/v24.20.0/SHASUMS256.txt (+ .sig, release keys)
# The GitHub workflow asks for go-version '1.26' (floating: latest 1.26.x, today
# go1.26.8) and node-version 24.20.0 (exact). CNB downloads exact archives with
# published SHA256 so a moved mirror or a swapped tag can never change the
# toolchain silently. Keep this pin deliberate, not "latest".
set -euo pipefail
set +x
unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo 'ERROR: unsupported CNB host runtime architecture' >&2; exit 1;
}
[ "$(id -u)" = 0 ] || { echo 'ERROR: runtime setup requires container root' >&2; exit 1; }
for tool in curl sha256sum tar; do command -v "$tool" >/dev/null || {
  echo "ERROR: runtime setup missing $tool" >&2; exit 1;
}; done
install_dir=/opt/cnb-openwrt-host
mkdir -p "$install_dir"
archive_dir="$(mktemp -d)"
trap 'rm -rf "$archive_dir"' EXIT

# SHA256 from https://go.dev/dl/?mode=json&include=all (go1.26.0 linux-amd64).
go_archive=go1.26.0.linux-amd64.tar.gz
go_sha=aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235
# SHA256 from https://nodejs.org/dist/v24.20.0/SHASUMS256.txt (linux-x64 tarball).
# The gzip tarball is used instead of .tar.xz so the job image needs no xz-utils;
# both archives unpack to the same node-v24.20.0-linux-x64/ tree with npm 11.19.0.
node_archive=node-v24.20.0-linux-x64.tar.gz
node_sha=855d581f8a4eb1a8117e3426de25fe02770592febcfb31369aee1ffbfee9e8ec
fetch_checked() {
  local url="$1" file="$2" checksum="$3"
  curl --fail --location --silent --show-error --retry 3 --retry-delay 5 \
    --connect-timeout 20 --max-time 600 "$url" -o "$archive_dir/$file"
  printf '%s  %s\n' "$checksum" "$archive_dir/$file" | sha256sum --check --status || {
    echo "ERROR: official host runtime archive checksum mismatch: $file" >&2; exit 1;
  }
}
fetch_checked "https://go.dev/dl/$go_archive" "$go_archive" "$go_sha"
fetch_checked "https://nodejs.org/dist/v24.20.0/$node_archive" "$node_archive" "$node_sha"
[ ! -e "$install_dir/go" ] && [ ! -e "$install_dir/node-v24.20.0-linux-x64" ] || {
  echo 'ERROR: host runtime destination is not empty' >&2; exit 1;
}
tar -xzf "$archive_dir/$go_archive" -C "$install_dir"
tar -xzf "$archive_dir/$node_archive" -C "$install_dir"
export PATH="$install_dir/go/bin:$install_dir/node-v24.20.0-linux-x64/bin:$PATH"
[ "$(go version)" = 'go version go1.26.0 linux/amd64' ] || {
  echo 'ERROR: host Go version mismatch' >&2; exit 1;
}
[ "$(node --version)" = 'v24.20.0' ] || { echo 'ERROR: host Node version mismatch' >&2; exit 1; }
# The agent runtime packaging step cross-installs with the npm bundled in this
# exact tarball, so assert it matches the setup-node 24.20.0 environment.
[ "$(npm --version)" = '11.19.0' ] || { echo 'ERROR: host npm version mismatch' >&2; exit 1; }
echo 'CNB host Go 1.26.0 and Node 24.20.0 checksum/version checks passed'
