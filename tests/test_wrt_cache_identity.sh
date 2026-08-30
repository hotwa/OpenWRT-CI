#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow" >&2; exit 1; }

for term in \
  'name: Compute Build Cache Identity' \
  'Config/${WRT_CONFIG}.txt' \
  'Scripts/Packages.sh' \
  'Scripts/Handles.sh' \
  'Scripts/Settings.sh' \
  'WRT_CACHE_KEY=$cache_key' \
  'key: ${{ env.WRT_CACHE_KEY }}' \
  'gh cache delete "$WRT_CACHE_KEY"'; do
  grep -Fq "$term" "$WORKFLOW" || {
    echo "WRT cache identity guard missing: $term" >&2
    exit 1
  }
done

if grep -Fq 'WRT_CACHE_DATE' "$WORKFLOW"; then
  echo "daily cache rotation would unnecessarily discard a compatible toolchain cache" >&2
  exit 1
fi

echo "WRT cache identity guards passed"
