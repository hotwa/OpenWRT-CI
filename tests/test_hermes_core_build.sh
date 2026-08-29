#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="$ROOT_DIR/Scripts/build_hermes_core.sh"
FETCH="$ROOT_DIR/Scripts/fetch_node_runtime.sh"

[ -f "$BUILDER" ] || { echo "missing Hermes Core builder"; exit 1; }
bash -n "$BUILDER"

# The npm bridge's postinstall performs a Git checkout, downloads its own uv,
# and enables every optional extra. None of those actions may be on the device
# path or accidentally reintroduced to the firmware builder.
grep -q -- '--ignore-scripts' "$FETCH" || { echo "npm ci still runs host postinstall"; exit 1; }
grep -q 'sync --locked --no-dev --no-install-project --no-editable' "$BUILDER" || {
  echo "Core builder no longer uses a locked Core-only sync"; exit 1;
}
if awk '!/^[[:space:]]*#/ { print }' "$BUILDER" | grep -Eq -- 'sync .*--extra[[:space:]]+all|sync .*--all-extras|--extra[[:space:]]+all'; then
  echo "Hermes Core builder must reject all extras"
  exit 1
fi

for term in \
  'HERMES_TARGET_RUNNER' \
  'qemu-aarch64' \
  'linux-arm64-musl' \
  'linux-x64-musl' \
  'UV_PYTHON_INSTALL_MIRROR' \
  'UV_PYTHON_INSTALL_DIR' \
  'remove only the manifest-verified Hermes 3.11 asset' \
  'source_tarball_sha256' \
  'lock_sha256' \
  'node_abi' \
  'python_sha256' \
  'extras": "core-only' \
  'import hermes_cli.main' \
  'Hermes Core Python has ELF machine' \
  'foreign ELF' \
  'host shebang'; do
  grep -q "$term" "$BUILDER" || { echo "Core builder missing gate: $term"; exit 1; }
done

# A fixture proves the source/layout checks fail before creating a runtime when
# the offline CPython contract is absent. It does not need an actual target ELF.
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/opt/node/bin" "$FIXTURE/usr/bin" \
  "$FIXTURE/opt/node/lib/node_modules/hermes-agent" "$FIXTURE/opt/uv/python-mirror"
printf '#!/bin/sh\nexit 0\n' >"$FIXTURE/opt/node/bin/node"
printf '#!/bin/sh\nexit 0\n' >"$FIXTURE/usr/bin/uv"
chmod 0755 "$FIXTURE/opt/node/bin/node" "$FIXTURE/usr/bin/uv"
printf '{}\n' >"$FIXTURE/opt/node/lib/node_modules/hermes-agent/package.json"
if bash "$BUILDER" "$FIXTURE" linux-x64-musl >"$FIXTURE/out" 2>&1; then
  echo "Core builder accepted a fixture without the offline CPython mirror"
  exit 1
fi
grep -q 'offline CPython mirror is missing' "$FIXTURE/out" || {
  echo "Core builder did not explain the offline mirror contract failure"
  exit 1
}

echo "Hermes Core build guards passed"
