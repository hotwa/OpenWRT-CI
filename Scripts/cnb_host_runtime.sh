#!/usr/bin/env bash
# Official host Go/Node downloads, pinned to the GitHub setup actions' versions.
set -euo pipefail
set +x
unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo 'ERROR: unsupported CNB host runtime architecture' >&2; exit 1;
}
[ "$(id -u)" = 0 ] || { echo 'ERROR: runtime setup requires container root' >&2; exit 1; }
for tool in curl sha256sum tar xz; do command -v "$tool" >/dev/null || {
  echo "ERROR: runtime setup missing $tool" >&2; exit 1;
}; done
install_dir=/opt/cnb-openwrt-host
mkdir -p "$install_dir"
archive_dir="$(mktemp -d)"
trap 'rm -rf "$archive_dir"' EXIT

# SHA256 from https://go.dev/dl/?mode=json&include=all (go1.26.0 linux-amd64).
go_archive=go1.26.0.linux-amd64.tar.gz
go_sha=aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235
# SHA256 from https://nodejs.org/dist/v24.20.0/SHASUMS256.txt (linux-x64).
node_archive=node-v24.20.0-linux-x64.tar.xz
node_sha=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
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
tar -xJf "$archive_dir/$node_archive" -C "$install_dir"
export PATH="$install_dir/go/bin:$install_dir/node-v24.20.0-linux-x64/bin:$PATH"
[ "$(go version)" = 'go version go1.26.0 linux/amd64' ] || {
  echo 'ERROR: host Go version mismatch' >&2; exit 1;
}
[ "$(node --version)" = 'v24.20.0' ] || { echo 'ERROR: host Node version mismatch' >&2; exit 1; }
echo 'CNB host Go 1.26.0 and Node 24.20.0 checksum/version checks passed'
