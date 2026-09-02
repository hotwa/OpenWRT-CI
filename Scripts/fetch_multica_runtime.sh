#!/bin/bash
# SPDX-License-Identifier: MIT
# Install the pinned, statically linked Multica CLI/daemon release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/retry.sh"

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_FILES="${1:-${ROOT_DIR}/wrt/files}"
[ -d "$TARGET_FILES" ] || TARGET_FILES="$ROOT_DIR/files"

MULTICA_VERSION="${MULTICA_VERSION:-0.4.38}"
MULTICA_REPO="multica-ai/multica"
MULTICA_RELEASE_BASE_URL="https://github.com/${MULTICA_REPO}/releases/download/v${MULTICA_VERSION}"

log_info() {
	printf 'INFO: [multica] %s\n' "$*"
}

die() {
	printf 'ERROR: [multica] %s\n' "$*" >&2
	exit 1
}

map_multica_arch() {
	case "${MULTICA_ARCH:-${WRT_ARCH:-}}" in
		x86_64|amd64|*x86_64*) printf '%s\n' amd64 ;;
		aarch64|arm64|armv8|*aarch64*|*armv8*|*ipq60*|*ipq807*|*filogic*) printf '%s\n' arm64 ;;
		*)
			if [ -n "${WRT_CONFIG:-}" ] && [ -f "$ROOT_DIR/Config/${WRT_CONFIG}.txt" ]; then
				if grep -Eq 'CONFIG_ARCH="aarch64"|CONFIG_TARGET_qualcommax=y' "$ROOT_DIR/Config/${WRT_CONFIG}.txt"; then
					printf '%s\n' arm64
					return
				fi
				if grep -Eq 'CONFIG_ARCH="x86_64"|CONFIG_TARGET_x86=y' "$ROOT_DIR/Config/${WRT_CONFIG}.txt"; then
					printf '%s\n' amd64
					return
				fi
			fi
			die "cannot determine target architecture; set WRT_ARCH or MULTICA_ARCH"
			;;
	esac
}

[[ "$MULTICA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| die "invalid MULTICA_VERSION: $MULTICA_VERSION"

ARCH="$(map_multica_arch)"
ASSET="multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz"
DEST_DIR="$TARGET_FILES/usr/local/bin"
SYS_BIN_DIR="$TARGET_FILES/usr/bin"
DEST_FILE="$DEST_DIR/multica"

TMP_DIR="$(mktemp -d)"
cleanup() {
	rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

ARCHIVE="$TMP_DIR/$ASSET"
CHECKSUMS="$TMP_DIR/checksums.txt"
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"

log_info "fetching pinned Multica v${MULTICA_VERSION} for linux-${ARCH}"
retry_cmd 3 5 curl --fail --silent --show-error --location \
	--proto '=https' --tlsv1.2 \
	"$MULTICA_RELEASE_BASE_URL/checksums.txt" -o "$CHECKSUMS" \
	|| die "failed to download official checksums.txt"
retry_cmd 3 5 curl --fail --silent --show-error --location \
	--proto '=https' --tlsv1.2 \
	"$MULTICA_RELEASE_BASE_URL/$ASSET" -o "$ARCHIVE" \
	|| die "failed to download official asset $ASSET"

EXPECTED_HASHES="$(awk -v asset="$ASSET" '$2 == asset && $1 ~ /^[[:xdigit:]]{64}$/ { print tolower($1) }' "$CHECKSUMS")"
[ "$(printf '%s\n' "$EXPECTED_HASHES" | sed '/^$/d' | wc -l)" -eq 1 ] \
	|| die "checksums.txt must contain exactly one valid entry for $ASSET"
EXPECTED_HASH="$(printf '%s\n' "$EXPECTED_HASHES" | sed -n '1p')"
ACTUAL_HASH="$(sha256sum "$ARCHIVE" | awk '{ print tolower($1) }')"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] \
	|| die "SHA256 verification failed for $ASSET"

# The official GoReleaser archive stores the binary at archive root. Reject
# path traversal and any unexpected binary layout before extracting anything.
if tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
	die "unsafe path in $ASSET"
fi
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" --no-same-owner

mapfile -t CANDIDATES < <(find "$EXTRACT_DIR" -type f \( -name multica -o -name multica-cli \) -print)
[ "${#CANDIDATES[@]}" -eq 1 ] || die "expected exactly one Multica binary in $ASSET"
EXTRACTED="${CANDIDATES[0]}"
chmod 755 "$EXTRACTED"

FILE_INFO="$(file -b "$EXTRACTED")"
case "$ARCH:$FILE_INFO" in
	amd64:*ELF*64-bit*x86-64*) ;;
	arm64:*ELF*64-bit*ARM*aarch64*) ;;
	*) die "downloaded binary architecture does not match linux-${ARCH}: $FILE_INFO" ;;
esac
printf '%s' "$FILE_INFO" | grep -qi 'statically linked' \
	|| die "Multica binary is not statically linked: $FILE_INFO"

mkdir -p "$DEST_DIR" "$SYS_BIN_DIR"
install -m 0755 "$EXTRACTED" "$DEST_FILE.tmp"
mv -f "$DEST_FILE.tmp" "$DEST_FILE"
ln -sfn /usr/local/bin/multica "$SYS_BIN_DIR/multica"

log_info "verified $ASSET ($ACTUAL_HASH) and installed $DEST_FILE"
