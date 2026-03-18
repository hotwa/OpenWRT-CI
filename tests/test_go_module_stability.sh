#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
INIT_SCRIPT="$ROOT_DIR/Scripts/init_build_environment.sh"

[ -f "$WORKFLOW" ] || { echo "missing workflow"; exit 1; }
[ -f "$INIT_SCRIPT" ] || { echo "missing init script"; exit 1; }

grep -q 'GOPROXY=https://proxy.golang.org|https://goproxy.cn|direct' "$WORKFLOW" || {
  echo "workflow missing GOPROXY export"
  exit 1
}

grep -q 'GOSUMDB=off' "$WORKFLOW" || {
  echo "workflow missing GOSUMDB override"
  exit 1
}

grep -q './wrt/dl/go-mod-cache' "$WORKFLOW" || {
  echo "workflow missing go mod cache path"
  exit 1
}

grep -q './wrt/tmp/go-build' "$WORKFLOW" || {
  echo "workflow missing go build cache path"
  exit 1
}

grep -q 'go env -w GOSUMDB=off' "$INIT_SCRIPT" || {
  echo "init script missing GOSUMDB setting"
  exit 1
}

echo "go module stability test passed"
