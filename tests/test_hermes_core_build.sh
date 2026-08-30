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
grep -qE 'sync --(frozen|locked) --no-dev --no-editable' "$BUILDER" || {
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

# `uv venv` writes its interpreter as an absolute link into the build overlay.
# The final image needs the corresponding immutable /opt link, but rebasing it
# before qemu verification would make it unavailable on the CI host. Exercise
# the extracted helper with a realistic staging-layout fixture.
grep -q 'rebase_venv_python_link' "$BUILDER" || {
  echo "Core builder does not rebase the staged Python symlink"
  exit 1
}
LINK_FIXTURE="$(mktemp -d)"
mkdir -p "$LINK_FIXTURE/files/opt/uv/python/cpython-3.11.16-linux-aarch64-musl/bin" \
  "$LINK_FIXTURE/files/opt/node/runtime/venv/bin"
printf '#!/bin/sh\nexit 0\n' >"$LINK_FIXTURE/files/opt/uv/python/cpython-3.11.16-linux-aarch64-musl/bin/python3.11"
chmod 0755 "$LINK_FIXTURE/files/opt/uv/python/cpython-3.11.16-linux-aarch64-musl/bin/python3.11"
ln -s "$LINK_FIXTURE/files/opt/uv/python/cpython-3.11.16-linux-aarch64-musl/bin/python3.11" \
  "$LINK_FIXTURE/files/opt/node/runtime/venv/bin/python"
sed -n '/^rebase_venv_python_link() {/,/^}/p' "$BUILDER" >"$LINK_FIXTURE/rebase.sh"
(
  die() { echo "unexpected rebase failure: $*" >&2; exit 1; }
  TARGET_FILES="$LINK_FIXTURE/files"
  VENV_DIR="$LINK_FIXTURE/files/opt/node/runtime/venv"
  # shellcheck disable=SC1090
  . "$LINK_FIXTURE/rebase.sh"
  rebase_venv_python_link
)
[ "$(readlink "$LINK_FIXTURE/files/opt/node/runtime/venv/bin/python")" = \
  '/opt/uv/python/cpython-3.11.16-linux-aarch64-musl/bin/python3.11' ] || {
  echo "Core builder kept a staging-only Python interpreter symlink"
  exit 1
}
rm -rf "$LINK_FIXTURE"

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
