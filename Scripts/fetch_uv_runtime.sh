#!/bin/bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

mkdir -p \
  "$ROOT_DIR/files/usr/bin" \
  "$ROOT_DIR/files/opt/uv/python" \
  "$ROOT_DIR/files/opt/uv/python-cache" \
  "$ROOT_DIR/files/opt/uv/python-mirror" \
  "$ROOT_DIR/files/opt/uv/cache"
