#!/bin/bash
# Build the Hermes *Core* runtime into a firmware overlay.
#
# This intentionally does not invoke hermes-agent's npm postinstall.  That
# script clones from GitHub, downloads another uv and executes
# a sync that enables every optional extra, which both produces host binaries during a cross build
# and leaves a new router dependent on the WAN.  We instead download the exact
# upstream commit named by the audited npm package, use the firmware's pinned
# musl uv + CPython mirror, and install only the upstream default dependency
# set (Core; no extras).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_FILES="${1:-$ROOT_DIR/files}"
NODE_TARGET="${2:-${NODE_TARGET_ARCH:-linux-arm64-musl}}"
NODE_ROOT="$TARGET_FILES/opt/node"
NODE_BIN="$NODE_ROOT/bin/node"
UV_BIN="$TARGET_FILES/usr/bin/uv"
MIRROR_DIR="$TARGET_FILES/opt/uv/python-mirror"
PYTHON_DIR="$TARGET_FILES/opt/uv/python"
HERMES_DIR="$NODE_ROOT/lib/node_modules/hermes-agent"
RUNTIME_DIR="$HERMES_DIR/runtime/hermes-agent"
VENV_DIR="$RUNTIME_DIR/venv"
METADATA_DIR="$TARGET_FILES/opt/agent-runtime"
METADATA_FILE="$METADATA_DIR/hermes-core.json"

log() { printf 'INFO: hermes-core: %s\n' "$*"; }
die() { printf 'ERROR: hermes-core: %s\n' "$*" >&2; exit 1; }

case "$NODE_TARGET" in
  linux-arm64-musl) npm_arch=arm64; elf_machine=183; qemu_arch=aarch64 ;;
  linux-x64-musl) npm_arch=x64; elf_machine=62; qemu_arch=x86_64 ;;
  *) die "unsupported target '$NODE_TARGET' (expected linux-arm64-musl or linux-x64-musl)" ;;
esac

[ -d "$TARGET_FILES" ] || die "target overlay does not exist: $TARGET_FILES"
[ -x "$NODE_BIN" ] || die "target Node binary is missing: $NODE_BIN"
[ -x "$UV_BIN" ] || die "target uv binary is missing: $UV_BIN"
[ -r "$MIRROR_DIR/manifest.txt" ] || die "offline CPython mirror is missing: $MIRROR_DIR/manifest.txt"
[ -f "$HERMES_DIR/package.json" ] || die "locked hermes-agent bridge is missing"

# A runner is deliberately explicit for ARM.  GitHub CI supplies qemu-user for
# the arm64 musl gate (for example HERMES_TARGET_RUNNER=qemu-aarch64); silently
# running a host x64 binary here would falsely certify the wrong architecture.
target_exec() {
  if [ -n "${HERMES_TARGET_RUNNER:-}" ]; then
    # The CI-owned runner is a command plus fixed arguments, not user input.
    # shellcheck disable=SC2086
    ${HERMES_TARGET_RUNNER} "$@"
  elif [ "$npm_arch" = arm64 ]; then
    command -v qemu-aarch64 >/dev/null 2>&1 || die "arm64 Core build requires qemu-aarch64 or HERMES_TARGET_RUNNER"
    qemu-aarch64 "$@"
  else
    "$@"
  fi
}

elf_machine_id() {
  local binary="$1" magic class data lo hi
  [ -f "$binary" ] || return 1
  magic="$(od -An -j 0 -N1 -tu1 -- "$binary" | tr -dc '0-9')"
  class="$(od -An -j 4 -N1 -tu1 -- "$binary" | tr -dc '0-9')"
  data="$(od -An -j 5 -N1 -tu1 -- "$binary" | tr -dc '0-9')"
  lo="$(od -An -j 18 -N1 -tu1 -- "$binary" | tr -dc '0-9')"
  hi="$(od -An -j 19 -N1 -tu1 -- "$binary" | tr -dc '0-9')"
  [ "$magic" = 127 ] && [ "$class" = 2 ] && [ "$data" = 1 ] || return 1
  printf '%s\n' "$((lo + hi * 256))"
}

json_value() {
  local expression="$1"
  if command -v node >/dev/null 2>&1; then
    node -e "const p=require(process.argv[1]); console.log($expression)" "$HERMES_DIR/package.json"
  else
    target_exec "$NODE_BIN" -e "const p=require(process.argv[1]); console.log($expression)" "$HERMES_DIR/package.json"
  fi
}

hermes_version="$(json_value 'p.version')"
python_series="$(json_value 'p.hermesAgent.pythonVersion')"
upstream_repo="$(json_value 'p.hermesAgent.upstreamRepository')"
upstream_commit="$(json_value 'p.hermesAgent.upstreamCommit')"
upstream_tag="$(json_value 'p.hermesAgent.upstreamGitTag')"
[[ "$hermes_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid npm version in hermes-agent package.json"
[[ "$python_series" =~ ^3\.[0-9]+$ ]] || die "invalid managed Python series '$python_series'"
[[ "$upstream_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid upstream repository metadata"
[[ "$upstream_commit" =~ ^[0-9a-f]{40}$ ]] || die "upstream commit must be a full SHA"
[[ "$upstream_tag" =~ ^v[A-Za-z0-9._-]+$ ]] || die "invalid upstream tag metadata"
awk -F '\t' -v series="$python_series" '$1 == series { found=1 } END { exit !found }' "$MIRROR_DIR/manifest.txt" ||
  die "offline mirror does not contain CPython $python_series"

build_dir="$(mktemp -d)"
cleanup() { rm -rf -- "$build_dir"; }
trap cleanup EXIT
archive="$build_dir/hermes.tar.gz"

log "fetching ${upstream_repo}@${upstream_commit} for ${NODE_TARGET}"
curl -fsSL --proto '=https' --tlsv1.2 \
  "https://codeload.github.com/${upstream_repo}/tar.gz/${upstream_commit}" -o "$archive"
source_sha256="$(sha256sum "$archive" | awk '{print $1}')"
mkdir -p "$build_dir/extract"
tar -xzf "$archive" -C "$build_dir/extract" --no-same-owner --no-same-permissions
source_root="$(find "$build_dir/extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$source_root" ] && [ -f "$source_root/pyproject.toml" ] && [ -f "$source_root/uv.lock" ] ||
  die "upstream archive lacks the locked Python project layout"
[ "$(find "$build_dir/extract" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] ||
  die "upstream archive has an unexpected top-level layout"

rm -rf -- "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
cp -a "$source_root/." "$RUNTIME_DIR/"
# Source control metadata and developer/test documentation are not runtime
# inputs.  Do not delete a directory merely because a future upstream renames
# it; these are optional space reductions only.
rm -rf -- "$RUNTIME_DIR/.git" "$RUNTIME_DIR/.github" \
  "$RUNTIME_DIR/tests" "$RUNTIME_DIR/test" "$RUNTIME_DIR/docs" \
  "$RUNTIME_DIR/website"

# The absolute paths below exist only while firmware is assembled.  uv writes
# them into console-script shebangs and pyvenv.cfg, so normalize after sync to
# their squashfs locations before the image is packed.
export UV_NO_CONFIG=true
export UV_PYTHON_INSTALL_MIRROR="file://$MIRROR_DIR"
export UV_PYTHON_INSTALL_DIR="$PYTHON_DIR"
export UV_CACHE_DIR="$build_dir/uv-cache"
export UV_PYTHON_INSTALL_BIN=false
export UV_PROJECT_ENVIRONMENT="$VENV_DIR"

log "creating managed Python $python_series from the offline mirror"
target_exec "$UV_BIN" venv --managed-python --python "$python_series" "$VENV_DIR"
export UV_PYTHON="$VENV_DIR/bin/python"
export VIRTUAL_ENV="$VENV_DIR"
log "syncing locked Hermes Core dependencies (no extras)"
target_exec "$UV_BIN" sync --locked --no-dev --no-install-project --no-editable --no-progress -C "$RUNTIME_DIR"

# The bridge always resolves the runtime below /opt/node.  A data generation
# can pass HERMES_RUNTIME_ROOT to the local coordinator without changing this
# immutable baseline path.
# `|` is the delimiter below; only it, backslash and replacement `&` need
# escaping.  Keeping this deliberately small also works for CI workspace paths
# containing punctuation.
staging_escaped="$(printf '%s' "$TARGET_FILES" | sed 's/[\\&|]/\\&/g')"
if grep -RIl --exclude='*.pyc' --exclude='*.so' "$TARGET_FILES" "$VENV_DIR" 2>/dev/null | grep -q .; then
  while IFS= read -r text_file; do
    sed -i "s|$staging_escaped||g" "$text_file"
  done < <(grep -RIl --exclude='*.pyc' --exclude='*.so' "$TARGET_FILES" "$VENV_DIR" || true)
fi
if grep -RIl --exclude='*.pyc' --exclude='*.so' "$TARGET_FILES" "$VENV_DIR" 2>/dev/null | grep -q .; then
  die "host staging paths remain in Hermes Core venv"
fi

# Gate every executable interpreter and console script before it gets baked.
[ -x "$VENV_DIR/bin/python" ] || die "uv did not create a Python interpreter"
[ -x "$VENV_DIR/bin/hermes" ] || die "uv did not install the Hermes Core console entrypoint"
python_target="$(readlink -f "$VENV_DIR/bin/python" 2>/dev/null || true)"
[ -n "$python_target" ] && [ -f "$python_target" ] || die "Hermes Core Python interpreter is not a regular target file"
python_machine="$(elf_machine_id "$python_target" || true)"
[ "$python_machine" = "$elf_machine" ] ||
  die "Hermes Core Python has ELF machine ${python_machine:-unknown}, expected $elf_machine"
python_interpreter="$(head -c 8192 "$python_target" | grep -a -m1 -oE '/lib[^ ]*/ld-[A-Za-z0-9._-]+' || true)"
[ -z "$python_interpreter" ] || printf '%s' "$python_interpreter" | grep -q musl ||
  die "Hermes Core Python has a non-musl ELF interpreter: $python_interpreter"
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  machine="$(elf_machine_id "$candidate" || true)"
  [ -z "$machine" ] || [ "$machine" = "$elf_machine" ] ||
    die "foreign ELF in Hermes Core: ${candidate#"$TARGET_FILES"} has machine $machine, expected $elf_machine"
  interpreter="$(head -c 8192 "$candidate" | grep -a -m1 -oE '/lib[^ ]*/ld-[A-Za-z0-9._-]+' || true)"
  [ -z "$interpreter" ] || printf '%s' "$interpreter" | grep -q musl ||
    die "non-musl ELF interpreter in Hermes Core: ${candidate#"$TARGET_FILES"} ($interpreter)"
done < <(find "$RUNTIME_DIR" -type f \( -name '*.so' -o -name '*.so.*' -o -name 'python*' \) -size +8k -print)
while IFS= read -r script; do
  [ -n "$script" ] || continue
  shebang="$(head -n1 "$script" 2>/dev/null || true)"
  case "$shebang" in
    '#!'*) printf '%s' "$shebang" | grep -q "$TARGET_FILES" && die "host shebang in ${script#"$TARGET_FILES"}" ;;
  esac
done < <(find "$VENV_DIR/bin" -type f -perm -0100 -print)

target_node_abi="$(target_exec "$NODE_BIN" -p 'process.versions.modules')"
target_node_arch="$(target_exec "$NODE_BIN" -p 'process.arch')"
[ "$target_node_arch" = "$npm_arch" ] || die "target node reports $target_node_arch, expected $npm_arch"
target_uv_version="$(target_exec "$UV_BIN" --version | awk '{print $2}')"
target_exec "$VENV_DIR/bin/python" -c 'import hermes_cli.main' >/dev/null
target_exec "$VENV_DIR/bin/hermes" --version >/dev/null

# `uv venv` has now expanded the exact 3.11 interpreter into the shared
# /opt/uv/python prefix. Keeping its install_only archive in python-mirror
# would ship the same interpreter twice.  Keep the other pinned series for
# their consumers, but remove only the manifest-verified Hermes 3.11 asset.
mirror_row="$(awk -F '\t' -v series="$python_series" '$1 == series { print; exit }' "$MIRROR_DIR/manifest.txt")"
[ -n "$mirror_row" ] || die "Hermes Python mirror row disappeared during Core build"
IFS='\t' read -r mirror_series mirror_build mirror_asset mirror_sha <<EOF
$mirror_row
EOF
[[ "$mirror_build" =~ ^[0-9]+$ ]] || die "invalid Hermes Python mirror build id"
case "$mirror_asset" in
  "cpython-${python_series}."*) ;;
  *) die "invalid Hermes Python mirror asset name" ;;
esac
case "$mirror_asset" in
  *+*-install_only.tar.gz) ;;
  *) die "invalid Hermes Python mirror asset name" ;;
esac
mirror_archive="$MIRROR_DIR/$mirror_build/$mirror_asset"
[ -f "$mirror_archive" ] || die "Hermes Python mirror archive is missing"
[ "$(sha256sum "$mirror_archive" | awk '{print $1}')" = "$mirror_sha" ] || die "Hermes Python mirror checksum changed"
rm -f -- "$mirror_archive"
rmdir "$MIRROR_DIR/$mirror_build" 2>/dev/null || true
sed -i "/^${python_series}[[:space:]]/d" "$MIRROR_DIR/manifest.txt"

core_lock_sha256="$(sha256sum "$RUNTIME_DIR/uv.lock" | awk '{print $1}')"
python_sha256="$(sha256sum "$VENV_DIR/bin/python" | awk '{print $1}')"
mkdir -p "$METADATA_DIR"
cat >"$METADATA_FILE" <<EOF
{
  "schema": 1,
  "component": "hermes-core",
  "core_root": "/opt/node/lib/node_modules/hermes-agent/runtime/hermes-agent",
  "npm_package": "hermes-agent",
  "npm_version": "$hermes_version",
  "upstream_repository": "$upstream_repo",
  "upstream_tag": "$upstream_tag",
  "upstream_commit": "$upstream_commit",
  "source_tarball_sha256": "$source_sha256",
  "lock_sha256": "$core_lock_sha256",
  "architecture": "$npm_arch",
  "libc": "musl",
  "node_abi": "$target_node_abi",
  "python_series": "$python_series",
  "uv_version": "$target_uv_version",
  "python_sha256": "$python_sha256",
  "extras": "core-only"
}
EOF

# This marker is consumed by the npm bridge and is generated from target facts,
# not the CI host.  Its update commands intentionally point to the signed
# whole-stack channel rather than Hermes' network update paths.
cat >"$HERMES_DIR/.hermes-agent-runtime.json" <<EOF
{"npmPackage":"hermes-agent","npmVersion":"$hermes_version","upstreamGitTag":"$upstream_tag","upstreamCommit":"$upstream_commit","pythonVersion":"$python_series","platform":"linux","arch":"$npm_arch","mode":"core-only","updateCommand":"agent-runtime upgrade"}
EOF

log "built verified Core-only runtime (${npm_arch}, Node ABI ${target_node_abi})"
