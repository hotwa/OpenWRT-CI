#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
PROFILE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"

[ -f "$SCRIPT" ] || { echo "missing 99-auto-mount-data script"; exit 1; }
[ -f "$PROFILE" ] || { echo "missing 20-node-agent.sh profile script"; exit 1; }

# 1. Syntax check
bash -n "$SCRIPT" || { echo "syntax error in 99-auto-mount-data"; exit 1; }
bash -n "$PROFILE" || { echo "syntax error in 20-node-agent.sh"; exit 1; }

# 2. Logic assertions
grep -Fq '/data/multica' "$SCRIPT" || {
	echo "99-auto-mount-data missing /data/multica directory creation"
	exit 1
}

grep -Fq 'link_directory /data/multica /root/.multica' "$SCRIPT" || {
	echo "99-auto-mount-data missing /root/.multica symlink"
	exit 1
}

grep -Fq 'MULTICA_WORKSPACE=/data/multica' "$PROFILE" || {
	echo "20-node-agent.sh missing MULTICA_WORKSPACE export"
	exit 1
}

grep -Fq 'UV_CACHE_DIR=/data/uv_cache' "$PROFILE" || {
	echo "20-node-agent.sh missing UV_CACHE_DIR export"
	exit 1
}

echo "auto mount data guard test passed"