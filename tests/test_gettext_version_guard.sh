#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLES="$ROOT_DIR/Scripts/Handles.sh"

[ -f "$HANDLES" ] || { echo "missing Handles.sh"; exit 1; }

grep -q 'GETTEXT_MAKEFILE="./libs/gettext-full/Makefile"' "$HANDLES" || {
	echo "Handles.sh is missing the gettext-full Makefile path"
	exit 1
}

grep -q 'PKG_VERSION:=0\\\.24\\\.1' "$HANDLES" || {
	echo "Handles.sh does not detect the pinned gettext 0.24.1"
	exit 1
}

grep -q 'PKG_VERSION:=0.24.2' "$HANDLES" || {
	echo "Handles.sh does not bump gettext-full to 0.24.2"
	exit 1
}

grep -q 'GETTEXT_OLD_HASH="6164ec7aa61653ac9cdfb41d5c2344563b21f707da1562712e48715f1d2052a6"' "$HANDLES" || {
	echo "Handles.sh does not guard the gettext 0.24.1 tarball hash"
	exit 1
}

grep -q 'GETTEXT_NEW_HASH="fcc0187f597aef6bc5bc95c629db1126315beb196b20570eaec6a4941850f7c5"' "$HANDLES" || {
	echo "Handles.sh does not pin the gettext 0.24.2 tarball hash"
	exit 1
}

grep -q 'DEPENDS:=+libunistring +libxml2' "$HANDLES" || {
	echo "Handles.sh does not apply the upstream libintl-full DEPENDS fix"
	exit 1
}

echo "gettext version guard test passed"
