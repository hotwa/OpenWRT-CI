#!/usr/bin/env bash
set -euo pipefail

# Fetch the latest stable official nerdctl full bundle and stage only the
# rootful binaries needed by this firmware. The bundle keeps nerdctl,
# containerd, runc, and CNI versions compatible with one another. BuildKit
# and rootless helpers are deliberately not copied into the firmware.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/retry.sh"

DEST_ROOT="${1:?destination OpenWrt files directory is required}"
API_URL="https://api.github.com/repos/containerd/nerdctl/releases/latest"
LATEST_URL="https://github.com/containerd/nerdctl/releases/latest"
DOWNLOAD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openwrt-container-runtime"
ARCHIVE_DIR="$DOWNLOAD_ROOT/archive"
EXTRACT_DIR="$DOWNLOAD_ROOT/extract"

rm -rf "$DOWNLOAD_ROOT"
mkdir -p "$ARCHIVE_DIR" "$EXTRACT_DIR"
trap 'rm -rf "$DOWNLOAD_ROOT"' EXIT

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "ERROR: tar is required" >&2; exit 1; }
command -v file >/dev/null 2>&1 || { echo "ERROR: file is required" >&2; exit 1; }

requested_version="${WRT_CONTAINER_RUNTIME_VERSION:-}"
if [ -n "$requested_version" ]; then
  case "$requested_version" in
    v[0-9]*.[0-9]*.[0-9]*) tag="$requested_version" ;;
    [0-9]*.[0-9]*.[0-9]*) tag="v$requested_version" ;;
    *) echo "ERROR: WRT_CONTAINER_RUNTIME_VERSION must be a semver version or v-prefixed tag" >&2; exit 1 ;;
  esac
else
  latest_url="$(retry_cmd 5 15 curl -fsSL -L -o /dev/null -w '%{url_effective}' \
    -A 'OpenWRT-CI-container-runtime' "$LATEST_URL")"
  tag="$(printf '%s\n' "$latest_url" | sed -n 's#^.*/tag/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p')"
fi

# GitHub's latest-release redirect avoids API rate limits. Keep the API as a
# fallback for mirrors/proxies that strip the redirect, but do not make jq a
# prerequisite for the normal path.
if [ -z "$tag" ]; then
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for GitHub API fallback" >&2; exit 1; }
  release_json="$ARCHIVE_DIR/release.json"
  retry_cmd 5 15 curl -fsSL --retry 3 --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: OpenWRT-CI-container-runtime' \
    "$API_URL" -o "$release_json"
  tag="$(jq -er '.tag_name' "$release_json")"
fi
case "$tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "ERROR: latest nerdctl release is not a stable semver tag: $tag" >&2; exit 1 ;;
esac
version="${tag#v}"
asset="nerdctl-full-${version}-linux-arm64.tar.gz"
base_url="https://github.com/containerd/nerdctl/releases/download/${tag}"
archive="$ARCHIVE_DIR/$asset"
sums="$ARCHIVE_DIR/SHA256SUMS"

retry_cmd 5 15 curl -fsSL --retry 3 --retry-delay 2 \
  -H 'User-Agent: OpenWRT-CI-container-runtime' \
  "$base_url/$asset" -o "$archive"
retry_cmd 5 15 curl -fsSL --retry 3 --retry-delay 2 \
  -H 'User-Agent: OpenWRT-CI-container-runtime' \
  "$base_url/SHA256SUMS" -o "$sums"

expected_sha="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1; exit }' "$sums")"
[ -n "$expected_sha" ] || { echo "ERROR: no SHA256SUMS entry for $asset" >&2; exit 1; }
actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
[ "$actual_sha" = "$expected_sha" ] || {
  echo "ERROR: SHA256 mismatch for $asset" >&2
  exit 1
}

# Reject path traversal before extraction. The official archive is expected to
# contain relative bin/ and libexec/cni paths only.
tar -tzf "$archive" | while IFS= read -r member; do
  case "$member" in
    /*|../*|*/../*|*/..|..)
      echo "ERROR: unsafe path in nerdctl archive: $member" >&2
      exit 1
      ;;
  esac
done
tar -xzf "$archive" -C "$EXTRACT_DIR" --no-same-owner

for binary in nerdctl containerd containerd-shim-runc-v2 ctr runc; do
  [ -f "$EXTRACT_DIR/bin/$binary" ] || {
    echo "ERROR: official bundle is missing bin/$binary" >&2
    exit 1
  }
  info="$(file -L "$EXTRACT_DIR/bin/$binary")"
  printf 'container runtime: %s\n' "$info"
  printf '%s\n' "$info" | grep -Eqi 'aarch64|ARM aarch64' || {
    echo "ERROR: bin/$binary is not an arm64 ELF binary" >&2
    exit 1
  }
  printf '%s\n' "$info" | grep -Eqi 'static' || {
    echo "ERROR: bin/$binary is not statically linked; refusing musl firmware injection" >&2
    exit 1
  }
done

install -d "$DEST_ROOT/usr/bin" "$DEST_ROOT/usr/sbin" \
  "$DEST_ROOT/usr/libexec/cni" "$DEST_ROOT/usr/share/container-runtime"
for binary in nerdctl containerd containerd-shim-runc-v2 ctr; do
  install -m 0755 "$EXTRACT_DIR/bin/$binary" "$DEST_ROOT/usr/bin/$binary"
done
install -m 0755 "$EXTRACT_DIR/bin/runc" "$DEST_ROOT/usr/sbin/runc"

# Keep only the plugins needed for host and bridge+nft operation.
# The full bundle contains many optional CNI drivers and would add tens of
# megabytes to a firmware whose root partition is already tight. Do not add
# CNI firewall/portmap to the default staged set: they can invoke iptables-nft
# while fw4/Nikki/Tailscale own nftables directly.
for cni_plugin in bridge host-local loopback tuning; do
  [ -f "$EXTRACT_DIR/libexec/cni/$cni_plugin" ] || {
    echo "ERROR: official bundle is missing CNI plugin $cni_plugin" >&2
    exit 1
  }
  install -m 0755 "$EXTRACT_DIR/libexec/cni/$cni_plugin" \
    "$DEST_ROOT/usr/libexec/cni/$cni_plugin"
done

bundle_readme="$(find "$EXTRACT_DIR" -type f -path '*/share/doc/nerdctl-full/README.md' -print -quit)"
containerd_version=""
runc_version=""
cni_version=""
if [ -n "$bundle_readme" ]; then
  containerd_version="$(sed -n 's/^- containerd: //p' "$bundle_readme" | sed -n '1p')"
  runc_version="$(sed -n 's/^- runc: //p' "$bundle_readme" | sed -n '1p')"
  cni_version="$(sed -n 's/^- CNI plugins: //p' "$bundle_readme" | sed -n '1p')"
fi

cat > "$DEST_ROOT/usr/share/container-runtime/versions" <<EOF
source=containerd/nerdctl
release=$tag
asset=$asset
asset_sha256=$actual_sha
containerd=${containerd_version:-unknown}
runc=${runc_version:-unknown}
cni=${cni_version:-unknown}
nerdctl=$version
EOF

[ -s "$DEST_ROOT/usr/share/container-runtime/versions" ] || {
  echo "ERROR: failed to write container runtime metadata" >&2
  exit 1
}
echo "Staged prebuilt nerdctl container runtime $tag ($actual_sha)"
