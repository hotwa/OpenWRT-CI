#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Stage one pinned, musl-native uv + CPython archive.  The archive is kept
# immutable under /opt and is expanded offline to /data by uv-runtime on the
# router.  Do not replace these exact base-runtime pins from the hourly agent
# bump workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/retry.sh"

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FILES_DIR="${1:-$ROOT_DIR/files}"
UV_BIN_DIR="$FILES_DIR/usr/bin"
UV_ROOT_DIR="$FILES_DIR/opt/uv"
UV_MIRROR_DIR="$UV_ROOT_DIR/python-mirror"

UV_VERSION="0.12.7"
UV_AARCH64_SHA256="6dcf60e3c085de88ace3671b949ca99f0652be561ff5627f0d21394140f041db"
UV_X86_64_SHA256="3d64d44ed67da7908dc7f5c4d64ebb44bad326fa17f8a0a52fc9a7793017bbe1"

PYTHON_SERIES="3.13"
PYTHON_VERSION="3.13.15"
PYTHON_RELEASE_TAG="20260825"
PYTHON_AARCH64_ASSET="cpython-3.13.15+20260825-aarch64-unknown-linux-musl-install_only_stripped.tar.gz"
PYTHON_AARCH64_SHA256="37289ba3f47bbd35539b96589f4d406a0657940e78298c66970dd71ec78dfb68"
PYTHON_X86_64_ASSET="cpython-3.13.15+20260825-x86_64-unknown-linux-musl-install_only_stripped.tar.gz"
PYTHON_X86_64_SHA256="14bf916d2c941cfaf88bb4457e966ed642dacb19d0ddae7f3a2c66cdc6b63354"
TMP=""

die() { printf 'ERROR: [uv runtime] %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: [uv runtime] %s\n' "$*" >&2; }

config_file() {
	if [ -n "${WRT_CONFIG:-}" ] && [ -f "$ROOT_DIR/Config/${WRT_CONFIG}.txt" ]; then
		printf '%s' "$ROOT_DIR/Config/${WRT_CONFIG}.txt"
	fi
}

map_target() {
	local config
	case "${UV_TARGET_TRIPLE:-}" in
		aarch64-unknown-linux-musl|x86_64-unknown-linux-musl) printf '%s' "$UV_TARGET_TRIPLE"; return 0 ;;
	esac
	case "${WRT_ARCH:-}" in
		*x86_64*|x86_64) printf '%s' x86_64-unknown-linux-musl; return 0 ;;
		*aarch64*|aarch64|*armv8*|armv8|*ipq60*|*ipq807*|*filogic*) printf '%s' aarch64-unknown-linux-musl; return 0 ;;
	esac
	config="$(config_file || true)"
	if [ -n "$config" ]; then
		grep -q '^CONFIG_TARGET_x86_64=y$' "$config" && { printf '%s' x86_64-unknown-linux-musl; return 0; }
		grep -Eq '^CONFIG_TARGET_(qualcommax|mediatek)=y$|^CONFIG_TARGET_(mediatek_filogic|rockchip_armv8)=y$' "$config" && { printf '%s' aarch64-unknown-linux-musl; return 0; }
	fi
	case "${WRT_TARGET:-}" in
		x86) printf '%s' x86_64-unknown-linux-musl ;;
		qualcommax|mediatek|rockchip) printf '%s' aarch64-unknown-linux-musl ;;
		*) return 1 ;;
	esac
}

asset_for_target() {
	case "$1" in
		aarch64-unknown-linux-musl) printf '%s\t%s\n' "$PYTHON_AARCH64_ASSET" "$PYTHON_AARCH64_SHA256" ;;
		x86_64-unknown-linux-musl) printf '%s\t%s\n' "$PYTHON_X86_64_ASSET" "$PYTHON_X86_64_SHA256" ;;
		*) return 1 ;;
	esac
}

uv_sha256_for_target() {
	case "$1" in
		aarch64-unknown-linux-musl) printf '%s' "$UV_AARCH64_SHA256" ;;
		x86_64-unknown-linux-musl) printf '%s' "$UV_X86_64_SHA256" ;;
		*) return 1 ;;
	esac
}

download_verified() {
	local url="$1" destination="$2" expected="$3" actual
	retry_cmd 5 15 curl -fsSL "$url" -o "$destination"
	actual="$(sha256sum "$destination" | awk '{print $1}')"
	[ "$actual" = "$expected" ] || die "SHA256 mismatch for $(basename "$destination")"
}

main() {
	local target uv_archive uv_hash uv_binary asset python_hash asset_path
	target="$(map_target)" || { warn "unsupported OpenWrt target; skipping uv staging"; return 0; }
	uv_archive="uv-${target}.tar.gz"
	uv_hash="$(uv_sha256_for_target "$target")" || die "missing uv checksum for $target"
	IFS=$'\t' read -r asset python_hash < <(asset_for_target "$target")

	mkdir -p "$UV_BIN_DIR" "$UV_ROOT_DIR" "$UV_MIRROR_DIR/$PYTHON_RELEASE_TAG"
	TMP="$(mktemp -d)"
	trap 'rm -rf -- "${TMP:-}"' EXIT
	download_verified "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_archive}" "$TMP/$uv_archive" "$uv_hash"
	tar -xzf "$TMP/$uv_archive" -C "$TMP"
	uv_binary="$(find "$TMP" -type f -name uv -print -quit)"
	[ -n "$uv_binary" ] || die "uv archive did not contain an executable"
	install -m 0755 "$uv_binary" "$UV_ROOT_DIR/uv"
	rm -f "$UV_BIN_DIR/uv"
	ln "$UV_ROOT_DIR/uv" "$UV_BIN_DIR/uv"

	asset_path="$UV_MIRROR_DIR/$PYTHON_RELEASE_TAG/$asset"
	download_verified "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE_TAG}/${asset}" "$asset_path" "$python_hash"
	# uv accepts either spelling.  Keep one archive, not a second compressed copy.
	ln -sfn "$asset" "$UV_MIRROR_DIR/$PYTHON_RELEASE_TAG/${asset/_stripped/}"
	cat >"$UV_MIRROR_DIR/manifest.txt" <<EOF
uv_version=$UV_VERSION
python_series=$PYTHON_SERIES
python_version=$PYTHON_VERSION
python_release_tag=$PYTHON_RELEASE_TAG
target=$target
asset=$asset
sha256=$python_hash
EOF
}

[ "${FETCH_UV_RUNTIME_LIBRARY_ONLY:-0}" = "1" ] || main "$@"
