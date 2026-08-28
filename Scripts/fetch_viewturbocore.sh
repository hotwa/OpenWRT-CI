#!/bin/bash
set -euo pipefail

. "$(dirname "$(realpath "$0")")/retry.sh"

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FILES_DIR="$ROOT_DIR/files"
INSTALL_DIR="$FILES_DIR/usr/local/bin"
TARGET_INSTALL_PATH="/usr/local/bin/viewturbocore"
BINARY_PATH="$FILES_DIR$TARGET_INSTALL_PATH"
ADDRESS="${VIEWTURBOCORE_ASSET_BASE:-https://assets.vtfly.com}"
# The vendor endpoint is versionless.  These digests pin the exact snapshot
# observed on 2026-08-27; a vendor-side replacement must be reviewed and the
# digest deliberately updated before it can enter a firmware image.
VIEWTURBOCORE_SNAPSHOT="2026-08-27"
VIEWTURBOCORE_AARCH64_SHA256="97f570fdb8c8d83a5130d2809bd1e37ec8796d00dfdc41a2fcd8abc4824a4f05"
VIEWTURBOCORE_X86_64_SHA256="2cba6def9e42070b8eaea3fa3566695ebfb30be2212ad1a9561459eb44516217"

config_file() {
	if [ -n "${WRT_CONFIG:-}" ] && [ -f "$ROOT_DIR/Config/${WRT_CONFIG}.txt" ]; then
		echo "$ROOT_DIR/Config/${WRT_CONFIG}.txt"
	fi
}

map_viewturbocore_asset() {
	local cfg

	case "${WRT_ARCH:-}" in
		*x86_64*|x86_64)
			echo "ViewTurboCore-x86_64-unknown-linux-gnu"
			return 0
			;;
		*aarch64*|aarch64|*arm64*|*armv8*|armv8|*ipq60*|*ipq807*|*filogic*)
			echo "ViewTurboCore-aarch64-unknown-linux-gnu"
			return 0
			;;
	esac

	cfg="$(config_file || true)"
	if [ -n "$cfg" ]; then
		if grep -q '^CONFIG_TARGET_x86_64=y$' "$cfg"; then
			echo "ViewTurboCore-x86_64-unknown-linux-gnu"
			return 0
		fi

		if grep -Eq '^CONFIG_TARGET_(qualcommax|mediatek)=y$' "$cfg" || \
			grep -Eq '^CONFIG_TARGET_(mediatek_filogic|rockchip_armv8)=y$' "$cfg"; then
			echo "ViewTurboCore-aarch64-unknown-linux-gnu"
			return 0
		fi
	fi

	case "${WRT_TARGET:-}" in
		x86)
			echo "ViewTurboCore-x86_64-unknown-linux-gnu"
			return 0
			;;
		qualcommax|mediatek|rockchip)
			echo "ViewTurboCore-aarch64-unknown-linux-gnu"
			return 0
			;;
	esac

	return 1
}

expected_sha256() {
	case "$1" in
		ViewTurboCore-aarch64-unknown-linux-gnu)
			echo "$VIEWTURBOCORE_AARCH64_SHA256"
			;;
		ViewTurboCore-x86_64-unknown-linux-gnu)
			echo "$VIEWTURBOCORE_X86_64_SHA256"
			;;
		*)
			return 1
			;;
	esac
}

verify_sha256() {
	local candidate="$1"
	local expected="$2"
	local actual

	actual="$(sha256sum "$candidate" | awk '{print $1}')"
	if [ "$actual" != "$expected" ]; then
		echo "ERROR: ViewTurboCore SHA256 mismatch for pinned snapshot $VIEWTURBOCORE_SNAPSHOT" >&2
		echo "ERROR: expected $expected, got $actual" >&2
		return 1
	fi
}

validate_binary() {
	local candidate="$1"

	if command -v file >/dev/null 2>&1; then
		local file_output
		file_output="$(file -b "$candidate")"
		case "$file_output" in
			*ELF* | *executable* | *shared\ object*)
				return 0
				;;
		esac
		echo "ERROR: downloaded file is not a valid Linux binary: $file_output" >&2
		return 1
	fi

	local elf_magic
	elf_magic="$(LC_ALL=C od -An -tx1 -N4 "$candidate" | tr -d '[:space:]')"
	if [ ! -s "$candidate" ] || [ "$elf_magic" != "7f454c46" ]; then
		echo "ERROR: downloaded file is not a valid ELF binary." >&2
		return 1
	fi
}

main() {
	local asset_name expected_hash tmp_binary

	if ! asset_name="$(map_viewturbocore_asset)"; then
		echo "WARN: skipping viewturbocore preload for unsupported target (WRT_TARGET=${WRT_TARGET:-unset}, WRT_ARCH=${WRT_ARCH:-unset})" >&2
		exit 0
	fi
	expected_hash="$(expected_sha256 "$asset_name")" || {
		echo "ERROR: no trusted checksum is pinned for $asset_name" >&2
		exit 1
	}

	mkdir -p "$INSTALL_DIR"
	tmp_binary="$(mktemp)"
	trap 'rm -f "$tmp_binary"' EXIT

	retry_cmd 5 15 curl -fsSL "$ADDRESS/others/linux/$asset_name" -o "$tmp_binary"
	verify_sha256 "$tmp_binary" "$expected_hash"
	validate_binary "$tmp_binary"

	install -m 0755 "$tmp_binary" "$BINARY_PATH"
	trap - EXIT
	rm -f "$tmp_binary"
}

main "$@"
