#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
FETCH_SCRIPT="$ROOT_DIR/Scripts/fetch_uv_runtime.sh"

[ -f "$GENERAL" ] || { echo "missing GENERAL config"; exit 1; }
[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$FETCH_SCRIPT" ] || { echo "missing fetch_uv_runtime.sh"; exit 1; }

grep -q '^CONFIG_PACKAGE_python3=y$' "$GENERAL" || {
  echo "GENERAL.txt does not enable full python3"
  exit 1
}

grep -q '^CONFIG_PACKAGE_python3-venv=y$' "$GENERAL" || {
  echo "GENERAL.txt does not enable python3-venv"
  exit 1
}

grep -q '\$GITHUB_WORKSPACE/Scripts/fetch_uv_runtime.sh' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not run fetch_uv_runtime.sh"
  exit 1
}

grep -q "python3-venv was dropped from .config after defconfig" "$WORKFLOW" || {
  echo "WRT-CORE.yml does not guard python3-venv after defconfig"
  exit 1
}

if grep -q "python3-light is still enabled after defconfig" "$WORKFLOW"; then
  echo "WRT-CORE.yml still treats python3-light as a failure after defconfig"
  exit 1
fi

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

grep -q 'uv-aarch64-unknown-linux-musl' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not support aarch64 musl uv assets"
  exit 1
}

grep -q 'uv-x86_64-unknown-linux-musl' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not support x86_64 musl uv assets"
  exit 1
}

grep -q 'UV_PYTHON_INSTALL_MIRROR' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not prepare a local Python install mirror"
  exit 1
}

grep -q 'python-build-standalone' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not mirror python-build-standalone assets"
  exit 1
}

grep -q 'github_api_download' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not use the authenticated GitHub API helper"
  exit 1
}

grep -q 'Authorization: Bearer' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not conditionally authenticate GitHub API requests"
  exit 1
}

grep -q 'RUNTIME_RELEASES_JSON=""' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not initialize release metadata cleanup state"
  exit 1
}

grep -q 'FETCH_UV_RUNTIME_LIBRARY_ONLY' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not expose its API helper for fixture tests"
  exit 1
}

if grep -q 'trap .*releases_json' "$FETCH_SCRIPT"; then
  echo "fetch_uv_runtime.sh still traps a function-local metadata path"
  exit 1
fi

grep -q 'python-build-standalone/releases/tags/' "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not pin a specific python-build-standalone release tag"
  exit 1
}

if grep -q 'python-build-standalone/releases?per_page=100}' "$FETCH_SCRIPT"; then
  echo "fetch_uv_runtime.sh still requests 100 oversized release metadata entries"
  exit 1
fi

grep -q "3.10 3.11 3.12 3.13" "$FETCH_SCRIPT" || {
  echo "fetch_uv_runtime.sh does not target Python 3.10-3.13"
  exit 1
}

# Functional regression: select_python_asset must match a pinned-style asset
# name. A double-escaped dot in the jq gsub once made every series unmatchable
# and surfaced as a misleading "has no asset" error.
FIXTURE_JSON="$(mktemp)"
trap 'rm -f "$FIXTURE_JSON"' EXIT
cat >"$FIXTURE_JSON" <<'EOF'
{
  "tag_name": "20260825",
  "draft": false,
  "prerelease": false,
  "assets": [
    {
      "name": "cpython-3.10.21+20260825-aarch64-unknown-linux-musl-install_only.tar.gz",
      "browser_download_url": "https://example.invalid/cpython-3.10.tar.gz"
    },
    {
      "name": "cpython-3.10.21+20260825-aarch64-unknown-linux-musl-install_only_stripped.tar.gz",
      "browser_download_url": "https://example.invalid/cpython-3.10-stripped.tar.gz"
    }
  ]
}
EOF

SELECTED_ROW="$(FETCH_UV_RUNTIME_LIBRARY_ONLY=1 bash -c '
  set -euo pipefail
  . "$1"
  select_python_asset "$2" "3.10" "aarch64-unknown-linux-musl"
' _ "$FETCH_SCRIPT" "$FIXTURE_JSON")" || {
  echo "select_python_asset failed on the fixture release"
  exit 1
}

case "$SELECTED_ROW" in
  cpython-3.10.21+20260825-aarch64-unknown-linux-musl-install_only.tar.gz*https://example.invalid/cpython-3.10.tar.gz) ;;
  *)
    echo "select_python_asset returned an unexpected row: $SELECTED_ROW"
    exit 1
    ;;
esac

EMPTY_ROW="$(FETCH_UV_RUNTIME_LIBRARY_ONLY=1 bash -c '
  set -euo pipefail
  . "$1"
  select_python_asset "$2" "3.11" "aarch64-unknown-linux-musl"
' _ "$FETCH_SCRIPT" "$FIXTURE_JSON")" || {
  echo "select_python_asset errored on a missing series"
  exit 1
}
[ -z "$EMPTY_ROW" ] || {
  echo "select_python_asset should return empty for a missing series"
  exit 1
}
rm -f "$FIXTURE_JSON"
trap - EXIT

echo "uv runtime preload guard test passed"
