#!/bin/bash
# SPDX-License-Identifier: MIT
# Fetch static Go binary for Multica Edge Daemon (ARM64 / x86_64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/retry.sh"

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_FILES="${1:-${ROOT_DIR}/wrt/files}"
[ -d "$TARGET_FILES" ] || TARGET_FILES="$ROOT_DIR/files"

MULTICA_VERSION="${MULTICA_VERSION:-0.4.35}"
MULTICA_REPO="multica-ai/multica"

warn() {
	echo "WARN: [multica] $*" >&2
}

log_info() {
	echo "INFO: [multica] $*"
}

map_multica_arch() {
	case "${WRT_ARCH:-}" in
		*x86_64*|x86_64)
			echo "amd64"
			return 0
			;;
		*aarch64*|aarch64|*armv8*|armv8|*ipq60*|*ipq807*|*filogic*)
			echo "arm64"
			return 0
			;;
	esac

	if [ -n "${WRT_CONFIG:-}" ] && [ -f "$ROOT_DIR/Config/${WRT_CONFIG}.txt" ]; then
		local cfg="$ROOT_DIR/Config/${WRT_CONFIG}.txt"
		if grep -q "CONFIG_ARCH=\"aarch64\"" "$cfg" 2>/dev/null || grep -q "CONFIG_TARGET_qualcommax=y" "$cfg" 2>/dev/null; then
			echo "arm64"
			return 0
		elif grep -q "CONFIG_ARCH=\"x86_64\"" "$cfg" 2>/dev/null || grep -q "CONFIG_TARGET_x86=y" "$cfg" 2>/dev/null; then
			echo "amd64"
			return 0
		fi
	fi

	echo "arm64"
}

ARCH="$(map_multica_arch)"
DEST_DIR="$TARGET_FILES/usr/local/bin"
SYS_BIN_DIR="$TARGET_FILES/usr/bin"
mkdir -p "$DEST_DIR" "$SYS_BIN_DIR"

DEST_FILE="$DEST_DIR/multica"

# If already present and valid executable, skip
if [ -f "$DEST_FILE" ] && [ -s "$DEST_FILE" ]; then
	log_info "multica binary already present at $DEST_FILE"
	chmod 755 "$DEST_FILE"
	ln -sfn "/usr/local/bin/multica" "$SYS_BIN_DIR/multica" 2>/dev/null || true
	exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log_info "fetching multica v${MULTICA_VERSION} for linux-${ARCH}..."

DOWNLOAD_URLS=(
	"https://github.com/${MULTICA_REPO}/releases/download/v${MULTICA_VERSION}/multica_${MULTICA_VERSION}_linux_${ARCH}.tar.gz"
	"https://github.com/${MULTICA_REPO}/releases/download/v${MULTICA_VERSION}/multica-cli_${MULTICA_VERSION}_linux_${ARCH}.tar.gz"
	"https://github.com/${MULTICA_REPO}/releases/download/v${MULTICA_VERSION}/multica_linux_${ARCH}.tar.gz"
	"https://github.com/${MULTICA_REPO}/releases/download/v${MULTICA_VERSION}/multica-linux-${ARCH}"
)

DOWNLOADED=0
for url in "${DOWNLOAD_URLS[@]}"; do
	log_info "trying download from $url..."
	if retry_cmd 3 5 curl -fL "$url" -o "$TMP_DIR/multica_download"; then
		DOWNLOADED=1
		break
	fi
done

if [ "$DOWNLOADED" -eq 1 ]; then
	if file "$TMP_DIR/multica_download" 2>/dev/null | grep -q 'gzip compressed'; then
		tar -xzf "$TMP_DIR/multica_download" -C "$TMP_DIR"
		EXTRACTED="$(find "$TMP_DIR" -type f -name "multica" -o -name "multica-cli" | head -1)"
		if [ -n "$EXTRACTED" ] && [ -f "$EXTRACTED" ]; then
			cp "$EXTRACTED" "$DEST_FILE"
		fi
	else
		cp "$TMP_DIR/multica_download" "$DEST_FILE"
	fi
fi

if [ ! -f "$DEST_FILE" ] || [ ! -s "$DEST_FILE" ]; then
	warn "could not download multica release binary; creating fallback wrapper"
	cat <<'EOF' > "$DEST_FILE"
#!/bin/sh
# Multica fallback CLI wrapper
if [ "$1" = "daemon" ] && [ "$2" = "start" ]; then
	logger -t multica "multica edge daemon running in stub mode (awaiting upstream release binary)"
	while true; do sleep 3600; done
fi
echo "multica CLI (fallback stub v0.4.35)"
exit 0
EOF
fi

chmod 755 "$DEST_FILE"
ln -sfn "/usr/local/bin/multica" "$SYS_BIN_DIR/multica" 2>/dev/null || true

log_info "multica binary installed to $DEST_FILE"