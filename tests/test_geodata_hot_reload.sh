#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATER="$ROOT_DIR/package/v2ray-geodata/v2ray-geodata-updater"

[ -f "$UPDATER" ] || { echo "missing v2ray geodata updater"; exit 1; }

grep -Fq 'if /etc/init.d/daed reload; then' "$UPDATER" || {
  echo "geodata updater does not reload daed after a successful update"
  exit 1
}

grep -Fq 'if /etc/init.d/dae hot_reload; then' "$UPDATER" || {
  echo "geodata updater does not hot-reload dae after a successful update"
  exit 1
}

grep -Fq 'daed reload failed, falling back to restart' "$UPDATER" || {
  echo "geodata updater is missing the daed restart fallback"
  exit 1
}

grep -Fq 'dae hot_reload failed, falling back to restart' "$UPDATER" || {
  echo "geodata updater is missing the dae restart fallback"
  exit 1
}

echo "geodata hot reload test passed"
