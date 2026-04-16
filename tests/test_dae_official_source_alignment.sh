#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAE_MAKEFILE="$ROOT_DIR/package/dae/Makefile"

[ -f "$DAE_MAKEFILE" ] || { echo "missing dae Makefile"; exit 1; }

grep -q '^PKG_SOURCE_URL:=https://github.com/daeuniverse/dae.git$' "$DAE_MAKEFILE" || {
	echo "dae Makefile is not aligned to the official dae upstream"
	exit 1
}

grep -q '^GIT_BRANCH:=main$' "$DAE_MAKEFILE" || {
	echo "dae Makefile is not pinned to the official main branch"
	exit 1
}

if grep -q 'git clone $(OUTBOUND_URL)' "$DAE_MAKEFILE"; then
	echo "dae Makefile still clones the outbound side repository during Build/Prepare"
	exit 1
fi

echo "dae official source alignment test passed"
