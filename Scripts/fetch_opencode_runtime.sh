#!/bin/bash
# fetch_opencode_runtime.sh - resolve opencode musl binary metadata at build time.
#
# Queries the npm registry for the latest opencode-linux-arm64-musl package
# and writes a key=value metadata file that the device-side opencode-runtime
# consumes to download, verify and install the single binary on first boot.
#
# The 185 MB binary is intentionally NOT downloaded here; the device fetches it
# on demand so the firmware image stays small.
#
# Usage:
#   fetch_opencode_runtime.sh [TARGET_FILES]
#
# Environment:
#   OPENCODE_VERSION  pin a specific version (default: npm registry "latest")
#   TARGET_FILES      override output root (default: $ROOT_DIR/files)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/retry.sh"

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_FILES="${1:-${ROOT_DIR}/wrt/files}"
[ -d "$TARGET_FILES" ] || TARGET_FILES="$ROOT_DIR/files"

NPM_PACKAGE="opencode-linux-arm64-musl"
NPM_REGISTRY="https://registry.npmjs.org"
OPENCODE_ARCH="linux-arm64-musl"

METADATA_DIR="$TARGET_FILES/etc/opencode"
METADATA_FILE="$METADATA_DIR/release-url"

log_info() { echo "INFO: $*"; }
warn()     { echo "WARN: $*" >&2; }

# Convert an npm integrity string ("sha512-<base64>") to lowercase hex.
# Falls back to openssl if xxd/base64+od pipeline is unavailable.
integrity_to_hex() {
	local integrity="$1" b64 hex
	case "$integrity" in
		sha512-*) b64="${integrity#sha512-}" ;;
		*)
			echo "ERROR: unsupported integrity algorithm: $integrity" >&2
			return 1
			;;
	esac
	if command -v base64 >/dev/null 2>&1 && command -v od >/dev/null 2>&1; then
		hex="$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
	elif command -v openssl >/dev/null 2>&1; then
		hex="$(printf '%s' "$b64" | base64 -d 2>/dev/null | openssl dgst -sha512 -binary 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
	else
		echo "ERROR: neither base64+od nor openssl available for integrity conversion" >&2
		return 1
	fi
	[ -n "$hex" ] || {
		echo "ERROR: failed to convert integrity to hex" >&2
		return 1
	}
	printf '%s' "$hex"
}

fetch_registry_json() {
	local version="$1" url
	if [ "$version" = "latest" ]; then
		url="${NPM_REGISTRY}/${NPM_PACKAGE}/latest"
	else
		url="${NPM_REGISTRY}/${NPM_PACKAGE}/${version}"
	fi
	retry_cmd 3 10 curl --fail --silent --show-error --location \
		--proto '=https' --tlsv1.2 \
		"$url"
}

main() {
	local version json tarball_url integrity sha512_hex
	version="${OPENCODE_VERSION:-latest}"

	log_info "Resolving opencode ${OPENCODE_ARCH} metadata (version=${version})..."
	json="$(fetch_registry_json "$version")"

	# Extract fields with grep/sed (no jq dependency in CI minimal images).
	tarball_url="$(printf '%s' "$json" | grep -o '"tarball"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tarball"[[:space:]]*:[[:space:]]*"//;s/"$//')"
	integrity="$(printf '%s' "$json" | grep -o '"integrity"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"integrity"[[:space:]]*:[[:space:]]*"//;s/"$//')"
	# version field: prefer the top-level "version":"x.y.z"
	version="$(printf '%s' "$json" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/"$//')"

	[ -n "$version" ] || { echo "ERROR: could not extract version from registry JSON" >&2; exit 1; }
	[ -n "$tarball_url" ] || { echo "ERROR: could not extract tarball URL from registry JSON" >&2; exit 1; }
	[ -n "$integrity" ] || { echo "ERROR: could not extract integrity from registry JSON" >&2; exit 1; }

	sha512_hex="$(integrity_to_hex "$integrity")"

	mkdir -p "$METADATA_DIR"
	{
		printf 'OPENCODE_VERSION=%s\n' "$version"
		printf 'OPENCODE_TARBALL_URL=%s\n' "$tarball_url"
		printf 'OPENCODE_SHA512=%s\n' "$sha512_hex"
		printf 'OPENCODE_ARCH=%s\n' "$OPENCODE_ARCH"
	} > "$METADATA_FILE"

	log_info "Wrote opencode metadata to ${METADATA_FILE#$ROOT_DIR/}"
	log_info "  version:  $version"
	log_info "  tarball:  $tarball_url"
	log_info "  sha512:   ${sha512_hex:0:16}...${sha512_hex: -16}"
	log_info "  arch:     $OPENCODE_ARCH"
}

main "$@"
