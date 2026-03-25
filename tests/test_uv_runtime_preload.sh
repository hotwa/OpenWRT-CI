#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_uv_runtime.sh"

[ -f "$GENERAL" ] || { echo "missing GENERAL config"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$FETCH_SCRIPT" ] || { echo "missing fetch_uv_runtime.sh"; exit 1; }

PYTHON_SPLIT_MATCHES="$(find "$ROOT_DIR/wrt/feeds" "$ROOT_DIR/wrt/package" -type f \( -name 'Makefile' -o -name '*.mk' \) 2>/dev/null \
  | xargs grep -nE 'Package/python3(|-[^:]+)|python3-light|venv' 2>/dev/null || true)"

grep -q '^CONFIG_PACKAGE_python3=y$' "$GENERAL" || {
  echo "GENERAL.txt does not enable full python3"
  exit 1
}

if grep -q '^CONFIG_PACKAGE_python3-light=y$' "$GENERAL"; then
  echo "GENERAL.txt still enables python3-light"
  exit 1
fi

if printf '%s\n' "$PYTHON_SPLIT_MATCHES" | grep -q 'Package/python3-venv'; then
  grep -q '^CONFIG_PACKAGE_python3-venv=y$' "$GENERAL" || {
    echo "GENERAL.txt does not enable python3-venv even though the checked-out buildroot exposes it"
    exit 1
  }
fi

grep -q '\$GITHUB_WORKSPACE/Scripts/fetch_uv_runtime.sh' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not run fetch_uv_runtime.sh"
  exit 1
}

FETCH_LINE="$(grep -n '\$GITHUB_WORKSPACE/Scripts/fetch_uv_runtime.sh' "$WORKFLOW" | head -n1 | cut -d: -f1)"
COPY_LINE="$(grep -n 'cp -rf ./files/. ./wrt/files/' "$WORKFLOW" | head -n1 | cut -d: -f1)"
[ -n "$FETCH_LINE" ] || { echo "missing fetch script line number"; exit 1; }
[ -n "$COPY_LINE" ] || { echo "missing files copy line number"; exit 1; }
[ "$FETCH_LINE" -lt "$COPY_LINE" ] || {
  echo "WRT-CORE.yml runs fetch_uv_runtime.sh after files/ has already been staged"
  exit 1
}

grep -q 'cp -rf ./files/. ./wrt/files/' "$WORKFLOW" || {
  echo "WRT-CORE.yml no longer stages files/ into wrt/files"
  exit 1
}

echo "uv runtime preload guard test passed"
