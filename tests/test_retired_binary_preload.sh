#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
legacy_name="view""turbo"
legacy_binary="${legacy_name}core"
vendor_name="vt""fly"
rc_local="$ROOT_DIR/files/etc/rc.local"

for removed_path in \
  "$ROOT_DIR/Scripts/fetch_${legacy_binary}.sh" \
  "$ROOT_DIR/files/usr/local/bin/${legacy_binary}"; do
  [ ! -e "$removed_path" ] || {
    echo "retired binary preload path remains: $removed_path" >&2
    exit 1
  }
done

[ -f "$rc_local" ] || {
  echo "missing rc.local overlay" >&2
  exit 1
}
for retained_line in \
  'rm -rf /.config' \
  'ln -sf /root/.config /.config' \
  'exit 0'; do
  tr -d '\r' < "$rc_local" | grep -Fxq "$retained_line" || {
    echo "rc.local lost retained startup behavior: $retained_line" >&2
    exit 1
  }
done

matches="$(rg -n -i --hidden \
  --glob '!.git/**' \
  -e "$legacy_name" \
  -e "$vendor_name" \
  "$ROOT_DIR" || true)"
[ -z "$matches" ] || {
  echo "retired binary preload references remain:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
}

echo "retired binary preload guard passed"
