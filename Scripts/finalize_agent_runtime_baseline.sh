#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Finalize the immutable firmware baseline after Node agents and Multica have
# been staged.
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET_FILES="${1:-$ROOT_DIR/wrt/files}"
[ -d "$TARGET_FILES" ] || TARGET_FILES="$ROOT_DIR/files"
BASELINE="$TARGET_FILES/opt/agent-runtime"
NODE="$TARGET_FILES/opt/node/bin/node"
NODE_VERSION_FILE="$TARGET_FILES/etc/agent-runtime/node-version"
UV_ROOT="$TARGET_FILES/opt/uv"
UV="$UV_ROOT/uv"
UV_MIRROR_MANIFEST="$UV_ROOT/python-mirror/manifest.txt"
MULTICA="$TARGET_FILES/usr/local/bin/multica"
MANIFEST="$BASELINE/manifest.json"
RUNTIME_RELEASE="${AGENT_RUNTIME_RELEASE:-$(sed -n '1p' "$ROOT_DIR/Scripts/node-agent-runtime/runtime-release")}"

die() { printf 'ERROR: [agent-runtime baseline] %s\n' "$*" >&2; exit 1; }
[[ "$RUNTIME_RELEASE" =~ ^[1-9][0-9]*$ ]] || die "runtime release must be a positive integer"
[ -x "$NODE" ] || die "missing staged Node runtime"
[ -s "$NODE_VERSION_FILE" ] || die "missing selected Node version contract"
[ -x "$UV" ] || die "missing staged uv runtime"
[ -s "$UV_MIRROR_MANIFEST" ] || die "missing staged Python mirror manifest"
[ -x "$MULTICA" ] || die "missing staged Multica runtime"

NODE_MACHINE="$(readelf -h "$NODE" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
case "$NODE_MACHINE" in
	AArch64) ARCH=arm64 ;;
	"Advanced Micro Devices X86-64") ARCH=x64 ;;
	*) die "unable to determine Node target architecture: ${NODE_MACHINE:-unknown}" ;;
esac
NODE_VERSION="$(tr -d '[:space:]' < "$NODE_VERSION_FILE")"
case "${NODE_VERSION%%.*}" in
	24) NODE_ABI=137 ;;
	22) NODE_ABI=127 ;;
	*) die "unsupported Node ABI contract for v$NODE_VERSION" ;;
esac

mkdir -p "$BASELINE/bin"
ln -sfn ../node "$BASELINE/node"
ln -sfn ../uv "$BASELINE/uv"
ln -sfn /usr/local/bin/multica "$BASELINE/bin/multica"

ROOT_DIR="$ROOT_DIR" TARGET_FILES="$TARGET_FILES" BASELINE="$BASELINE" \
  NODE="$NODE" NODE_VERSION_FILE="$NODE_VERSION_FILE" UV="$UV" UV_MIRROR_MANIFEST="$UV_MIRROR_MANIFEST" MULTICA="$MULTICA" MANIFEST="$MANIFEST" \
  RUNTIME_RELEASE="$RUNTIME_RELEASE" ARCH="$ARCH" NODE_ABI="$NODE_ABI" node <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const e = process.env;
const sha = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const deps = JSON.parse(fs.readFileSync(path.join(e.ROOT_DIR, 'Scripts/node-agent-runtime/package.json'))).dependencies;
const pi = JSON.parse(fs.readFileSync(path.join(e.ROOT_DIR, 'Scripts/node-agent-runtime/vendor/pi-plan-mode/provenance.json')));
const nodeVersion = fs.readFileSync(e.NODE_VERSION_FILE, 'utf8').trim();
const multicaScript = fs.readFileSync(path.join(e.ROOT_DIR, 'Scripts/fetch_multica_runtime.sh'), 'utf8');
const multica = multicaScript.match(/^MULTICA_VERSION="\$\{MULTICA_VERSION:-([0-9.]+)\}"/m)?.[1];
const uvScript = fs.readFileSync(path.join(e.ROOT_DIR, 'Scripts/fetch_uv_runtime.sh'), 'utf8');
const uv = uvScript.match(/^UV_VERSION="([0-9.]+)"/m)?.[1];
const pythonVersion = uvScript.match(/^PYTHON_VERSION="([0-9.]+)"/m)?.[1];
const pythonReleaseTag = uvScript.match(/^PYTHON_RELEASE_TAG="([0-9]+)"/m)?.[1];
if (!nodeVersion || !multica || !uv || !pythonVersion || !pythonReleaseTag || !['arm64', 'x64'].includes(e.ARCH) || !Number.isSafeInteger(Number(e.NODE_ABI))) throw new Error('invalid baseline component metadata');
const manifest = {
  schema_version: 1,
  runtime_release: Number(e.RUNTIME_RELEASE),
  architecture: e.ARCH,
  libc: 'musl',
  source: 'firmware',
  runtime_contract: {
    node_version: nodeVersion,
    node_abi: Number(e.NODE_ABI),
    uv_version: uv,
    python_series: '3.13',
    python_version: pythonVersion,
    python_release_tag: pythonReleaseTag
  },
  components: {...deps, multica, uv, cpython: pythonVersion, 'pi-plan-mode': pi.version},
  vendored_extensions: {'pi-plan-mode': pi},
  critical_elf_sha256: {'node/bin/node': sha(e.NODE), 'uv/uv': sha(e.UV), 'bin/multica': sha(e.MULTICA)}
};
fs.writeFileSync(e.MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`, {mode: 0o644});
NODE

[ -s "$MANIFEST" ] || die "baseline manifest was not written"
printf 'INFO: finalized firmware agent runtime baseline release %s\n' "$RUNTIME_RELEASE"
