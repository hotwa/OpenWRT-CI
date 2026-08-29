#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Finalize the immutable firmware baseline after uv, Node agents, Hermes Core,
# and Multica have all been staged.
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET_FILES="${1:-$ROOT_DIR/wrt/files}"
[ -d "$TARGET_FILES" ] || TARGET_FILES="$ROOT_DIR/files"
BASELINE="$TARGET_FILES/opt/agent-runtime"
HERMES="$BASELINE/hermes-core.json"
NODE="$TARGET_FILES/opt/node/bin/node"
NODE_VERSION_FILE="$TARGET_FILES/etc/agent-runtime/node-version"
UV="$TARGET_FILES/opt/uv"
MULTICA="$TARGET_FILES/usr/local/bin/multica"
MANIFEST="$BASELINE/manifest.json"
RUNTIME_RELEASE="${AGENT_RUNTIME_RELEASE:-$(sed -n '1p' "$ROOT_DIR/Scripts/node-agent-runtime/runtime-release")}"
PYTHON_SERIES="$(sed -n 's/^PYTHON_SERIES=(\(.*\))$/\1/p' "$ROOT_DIR/Scripts/fetch_uv_runtime.sh")"

die() { printf 'ERROR: [agent-runtime baseline] %s\n' "$*" >&2; exit 1; }
[[ "$RUNTIME_RELEASE" =~ ^[1-9][0-9]*$ ]] || die "runtime release must be a positive integer"
[ -x "$NODE" ] || die "missing staged Node runtime"
[ -s "$NODE_VERSION_FILE" ] || die "missing selected Node version contract"
[ -d "$UV" ] || die "missing staged uv runtime"
[ -x "$MULTICA" ] || die "missing staged Multica runtime"
[ -s "$HERMES" ] || die "missing staged Hermes Core metadata"

mkdir -p "$BASELINE/bin"
ln -sfn ../node "$BASELINE/node"
ln -sfn ../uv "$BASELINE/uv"
ln -sfn /usr/local/bin/multica "$BASELINE/bin/multica"

ROOT_DIR="$ROOT_DIR" TARGET_FILES="$TARGET_FILES" BASELINE="$BASELINE" \
  HERMES="$HERMES" NODE="$NODE" NODE_VERSION_FILE="$NODE_VERSION_FILE" MULTICA="$MULTICA" MANIFEST="$MANIFEST" \
  RUNTIME_RELEASE="$RUNTIME_RELEASE" PYTHON_SERIES="$PYTHON_SERIES" node <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const e = process.env;
const sha = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const deps = JSON.parse(fs.readFileSync(path.join(e.ROOT_DIR, 'Scripts/node-agent-runtime/package.json'))).dependencies;
const core = JSON.parse(fs.readFileSync(e.HERMES));
const pi = JSON.parse(fs.readFileSync(path.join(e.ROOT_DIR, 'Scripts/node-agent-runtime/vendor/pi-plan-mode/provenance.json'));
const nodeVersion = fs.readFileSync(e.NODE_VERSION_FILE, 'utf8').trim();
const multicaScript = fs.readFileSync(path.join(e.ROOT_DIR, 'Scripts/fetch_multica_runtime.sh'), 'utf8');
const multica = multicaScript.match(/^MULTICA_VERSION="\$\{MULTICA_VERSION:-([0-9.]+)\}"/m)?.[1];
if (!nodeVersion || !multica || !['arm64', 'x64'].includes(core.architecture)) throw new Error('invalid baseline component metadata');
const manifest = {
  schema_version: 1,
  runtime_release: Number(e.RUNTIME_RELEASE),
  architecture: core.architecture,
  libc: 'musl',
  source: 'firmware',
  runtime_contract: {
    node_version: nodeVersion,
    node_abi: Number(core.node_abi),
    uv_version: core.uv_version,
    cpython_series: e.PYTHON_SERIES.trim().split(/\s+/)
  },
  components: {...deps, multica, 'hermes-core': core.npm_version, 'pi-plan-mode': pi.version},
  hermes_core: core,
  vendored_extensions: {'pi-plan-mode': pi},
  critical_elf_sha256: {'node/bin/node': sha(e.NODE), 'bin/multica': sha(e.MULTICA)}
};
fs.writeFileSync(e.MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`, {mode: 0o644});
NODE

[ -s "$MANIFEST" ] || die "baseline manifest was not written"
printf 'INFO: finalized firmware agent runtime baseline release %s\n' "$RUNTIME_RELEASE"
