#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/retry.sh"

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FILES_DIR="${1:-$ROOT_DIR/files}"
UV_BIN_DIR="$FILES_DIR/usr/bin"
UV_ROOT_DIR="$FILES_DIR/opt/uv"
UV_PYTHON_DIR="$UV_ROOT_DIR/python"
UV_PYTHON_CACHE_DIR="$UV_ROOT_DIR/python-cache"
UV_PYTHON_MIRROR_DIR="$UV_ROOT_DIR/python-mirror"
UV_CACHE_DIR="$UV_ROOT_DIR/cache"
UV_PYTHON_INSTALL_MIRROR="file:///opt/uv/python-mirror"
UV_AARCH64_ASSET="uv-aarch64-unknown-linux-musl"
UV_X86_64_ASSET="uv-x86_64-unknown-linux-musl"
UV_VERSION="0.12.7"
UV_AARCH64_SHA256="6dcf60e3c085de88ace3671b949ca99f0652be561ff5627f0d21394140f041db"
UV_X86_64_SHA256="3d64d44ed67da7908dc7f5c4d64ebb44bad326fa17f8a0a52fc9a7793017bbe1"
PYTHON_RELEASE_TAG="20260825"
PYTHON_RELEASES_API="https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/$PYTHON_RELEASE_TAG"
PYTHON_SHA256SUMS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE_TAG/SHA256SUMS"
PYTHON_SERIES=(3.10 3.11 3.12 3.13)
RUNTIME_RELEASES_JSON=""
RUNTIME_CHECKSUMS_FILE=""

warn() {
	echo "WARN: $*" >&2
}

cleanup_runtime_metadata() {
	[ -z "$RUNTIME_RELEASES_JSON" ] || rm -f -- "$RUNTIME_RELEASES_JSON"
	[ -z "$RUNTIME_CHECKSUMS_FILE" ] || rm -f -- "$RUNTIME_CHECKSUMS_FILE"
}

github_api_download() {
	local url="$1" output_file="$2" token attempt=1
	local -a auth_args=()

	token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
	if [ -n "$token" ]; then
		auth_args=(-H "Authorization: Bearer $token")
	fi

	while [ "$attempt" -le 5 ]; do
		if curl -fsSL \
			-H "Accept: application/vnd.github+json" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"${auth_args[@]}" "$url" -o "$output_file"; then
			return 0
		fi
		warn "GitHub API request failed (attempt $attempt/5): $url"
		[ "$attempt" -eq 5 ] && break
		sleep 15
		attempt=$((attempt + 1))
	done

	echo "ERROR: unable to download pinned release metadata from GitHub API; check network access or API rate limits" >&2
	return 1
}

config_file() {
	if [ -n "${WRT_CONFIG:-}" ] && [ -f "$ROOT_DIR/Config/${WRT_CONFIG}.txt" ]; then
		echo "$ROOT_DIR/Config/${WRT_CONFIG}.txt"
	fi
}

map_uv_target() {
	local cfg

	case "${UV_TARGET_TRIPLE:-}" in
		aarch64-unknown-linux-musl|x86_64-unknown-linux-musl)
			echo "$UV_TARGET_TRIPLE"
			return 0
			;;
	esac

	case "${WRT_ARCH:-}" in
		*x86_64*|x86_64)
			echo "${UV_X86_64_ASSET#uv-}"
			return 0
			;;
		*aarch64*|aarch64|*armv8*|armv8|*ipq60*|*ipq807*|*filogic*)
			echo "${UV_AARCH64_ASSET#uv-}"
			return 0
			;;
	esac

	cfg="$(config_file || true)"
	if [ -n "$cfg" ]; then
		if grep -q '^CONFIG_TARGET_x86_64=y$' "$cfg"; then
			echo "${UV_X86_64_ASSET#uv-}"
			return 0
		fi

		if grep -Eq '^CONFIG_TARGET_(qualcommax|mediatek)=y$' "$cfg" || \
			grep -Eq '^CONFIG_TARGET_(mediatek_filogic|rockchip_armv8)=y$' "$cfg"; then
			echo "${UV_AARCH64_ASSET#uv-}"
			return 0
		fi
	fi

	case "${WRT_TARGET:-}" in
		x86)
			echo "${UV_X86_64_ASSET#uv-}"
			return 0
			;;
		qualcommax|mediatek|rockchip)
			echo "${UV_AARCH64_ASSET#uv-}"
			return 0
			;;
	esac

	return 1
}

prepare_overlay_dirs() {
	mkdir -p \
		"$UV_BIN_DIR" \
		"$UV_PYTHON_DIR" \
		"$UV_PYTHON_CACHE_DIR" \
		"$UV_PYTHON_MIRROR_DIR" \
		"$UV_CACHE_DIR"
}

uv_archive_sha256() {
	case "$1" in
		aarch64-unknown-linux-musl)
			echo "$UV_AARCH64_SHA256"
			;;
		x86_64-unknown-linux-musl)
			echo "$UV_X86_64_SHA256"
			;;
		*)
			return 1
			;;
	esac
}

download_uv_binary() (
	local uv_target="$1"
	local uv_version="$UV_VERSION"
	local archive="uv-${uv_target}.tar.gz"
	local url="https://github.com/astral-sh/uv/releases/download/${uv_version}/${archive}"
	local expected_hash actual_hash tmpdir uv_binary

	expected_hash="$(uv_archive_sha256 "$uv_target")" || {
		echo "ERROR: no trusted uv checksum is pinned for $uv_target" >&2
		return 1
	}

	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT
	retry_cmd 5 15 curl -fsSL "$url" -o "$tmpdir/$archive"
	actual_hash="$(sha256sum "$tmpdir/$archive" | awk '{print $1}')"
	if [ "$actual_hash" != "$expected_hash" ]; then
		echo "ERROR: uv $uv_version archive SHA256 mismatch for $uv_target" >&2
		return 1
	fi
	tar -xzf "$tmpdir/$archive" -C "$tmpdir"
	uv_binary="$(find "$tmpdir" -type f -name uv -print -quit)"
	[ -n "$uv_binary" ] || {
		echo "ERROR: failed to locate extracted uv binary for $uv_target" >&2
		return 1
	}
	install -m 0755 "$uv_binary" "$UV_BIN_DIR/uv"
)

prepare_mirror_manifest() {
	cat >"$UV_PYTHON_MIRROR_DIR/manifest.txt" <<EOF
mirror=$UV_PYTHON_INSTALL_MIRROR
EOF
}

select_python_asset() {
	local releases_json="$1"
	local series="$2"
	local pbs_target="$3"

	jq -r --arg series "$series" --arg target "$pbs_target" '
		[
			select((.draft // false) == false and (.prerelease // false) == false)
			| (.assets // [])[]
			| select(.name | test("^cpython-" + ($series | gsub("\\."; "\\.")) + "\\.[0-9]+\\+[0-9]+-" + $target + "-install_only\\.tar\\.gz$"))
			| [.name, .browser_download_url]
			| @tsv
		][0] // empty
	' "$releases_json"
}

mirror_python_series() {
	local pbs_target="$1"
	local releases_json="$2"
	local checksums_file="$3"
	local manifest="$UV_PYTHON_MIRROR_DIR/manifest.txt"
	local row asset_name asset_url build_id expected_hash actual_hash asset_path

	for series in "${PYTHON_SERIES[@]}"; do
		row="$(select_python_asset "$releases_json" "$series" "$pbs_target")"
		if [ -z "$row" ]; then
			echo "ERROR: pinned CPython $PYTHON_RELEASE_TAG has no $series asset for $pbs_target" >&2
			return 1
		fi

		IFS=$'\t' read -r asset_name asset_url <<EOF
$row
EOF

		build_id=""
		if [[ "$asset_name" =~ \+([0-9]+)- ]]; then
			build_id="${BASH_REMATCH[1]}"
		fi
		if [ -z "$build_id" ]; then
			echo "ERROR: unable to parse build id from $asset_name" >&2
			return 1
		fi

		mkdir -p "$UV_PYTHON_MIRROR_DIR/$build_id"
		asset_path="$UV_PYTHON_MIRROR_DIR/$build_id/$asset_name"
		expected_hash="$(awk -v name="$asset_name" '$2 == name { print $1; exit }' "$checksums_file")"
		[ -n "$expected_hash" ] || {
			echo "ERROR: $asset_name is absent from the official SHA256SUMS" >&2
			return 1
		}
		retry_cmd 5 15 curl -fsSL "$asset_url" -o "$asset_path"
		actual_hash="$(sha256sum "$asset_path" | awk '{print $1}')"
		if [ "$actual_hash" != "$expected_hash" ]; then
			echo "ERROR: CPython archive SHA256 mismatch for $asset_name" >&2
			return 1
		fi
		printf '%s\t%s\t%s\t%s\n' "$series" "$build_id" "$asset_name" "$expected_hash" >>"$manifest"
	done
}

fetch_python_releases_json() {
	local output_file="$1"

	github_api_download "$PYTHON_RELEASES_API" "$output_file" || return 1
	[ "$(jq -r '.tag_name // empty' "$output_file")" = "$PYTHON_RELEASE_TAG" ] || {
		echo "ERROR: python-build-standalone release metadata did not match $PYTHON_RELEASE_TAG" >&2
		return 1
	}
}

main() {
	local uv_target

	prepare_overlay_dirs

	if ! uv_target="$(map_uv_target)"; then
		warn "skipping uv preload for unsupported target (WRT_TARGET=${WRT_TARGET:-unset}, WRT_ARCH=${WRT_ARCH:-unset})"
		exit 0
	fi

	download_uv_binary "$uv_target"
	prepare_mirror_manifest

	RUNTIME_RELEASES_JSON="$(mktemp)"
	RUNTIME_CHECKSUMS_FILE="$(mktemp)"
	trap cleanup_runtime_metadata EXIT
	fetch_python_releases_json "$RUNTIME_RELEASES_JSON"
	retry_cmd 5 15 curl -fsSL "$PYTHON_SHA256SUMS_URL" -o "$RUNTIME_CHECKSUMS_FILE"
	mirror_python_series "$uv_target" "$RUNTIME_RELEASES_JSON" "$RUNTIME_CHECKSUMS_FILE"
	cleanup_runtime_metadata
	trap - EXIT
}

[ "${FETCH_UV_RUNTIME_LIBRARY_ONLY:-0}" = "1" ] || main "$@"
