#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build a deterministic, signed-metadata-ready agent-runtime generation bundle.
#
# The bundle deliberately does not contain manifest.json.  A SHA256 cannot be
# embedded in the very archive it hashes without a circular dependency.  The
# signed, detached manifest is verified first and copied to the generation
# root by agent-runtime after extraction.  Therefore every installed
# generation still has <generation>/manifest.json.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCE=""
OUTPUT_DIR=""
ARCH=""
RUNTIME_RELEASE=""

die() { printf 'ERROR: [agent-runtime bundle] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: package_agent_runtime_bundle.sh --source DIR --output DIR --arch arm64|x64 --runtime-release N

DIR is the *contents* of one immutable generation.  It must contain node/, uv/
and bin/multica.  The command writes a .tar.gz payload and its detached
manifest.json to OUTPUT.  The device manager verifies the detached manifest,
extracts the payload, then installs that same manifest as generation/manifest.json.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --runtime-release) RUNTIME_RELEASE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$SOURCE" ] && [ -n "$OUTPUT_DIR" ] && [ -n "$ARCH" ] && [ -n "$RUNTIME_RELEASE" ] || {
  usage >&2; exit 64;
}
case "$ARCH" in arm64|x64) ;; *) die "--arch must be arm64 or x64" ;; esac
[[ "$RUNTIME_RELEASE" =~ ^[1-9][0-9]*$ ]] || die "runtime_release must be a positive integer"
SOURCE="$(realpath -e "$SOURCE")"
[ -d "$SOURCE/node" ] || die "generation source is missing node/"
[ -x "$SOURCE/uv/uv" ] || die "generation source is missing executable uv/uv"
[ -s "$SOURCE/uv/python-mirror/manifest.txt" ] || die "generation source is missing pinned Python mirror"
[ -x "$SOURCE/bin/multica" ] || die "generation source is missing executable bin/multica"
[ -s "$SOURCE/node-version" ] || die "generation source is missing node-version"
[ -s "$SOURCE/vendor/pi-plan-mode/provenance.json" ] || die "generation source is missing vendored Pi plan-mode provenance"
[ -s "$SOURCE/node/agent-runtime-package.json" ] || die "generation source is missing resolved Node catalog"
[ -s "$SOURCE/node/agent-runtime-package-lock.json" ] || die "generation source is missing resolved Node lockfile"
[ -s "$SOURCE/node/agent-runtime-resolved.json" ] || die "generation source is missing resolved Node component metadata"

# A hostile symlink must never make a signed bundle read a host path outside
# the prepared generation.  Internal links (for npm .bin, etc.) are valid.
while IFS= read -r -d '' link; do
  resolved="$(realpath -e "$link")" || die "broken symlink: ${link#$SOURCE/}"
  case "$resolved" in "$SOURCE"|"$SOURCE"/*) ;; *) die "escaping symlink: ${link#$SOURCE/}" ;; esac
done < <(find "$SOURCE" -type l -print0)

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(realpath -e "$OUTPUT_DIR")"
NAME="agent-runtime-${RUNTIME_RELEASE}-${ARCH}-musl"
BUNDLE="$OUTPUT_DIR/$NAME.tar.gz"
MANIFEST="$OUTPUT_DIR/$NAME.manifest.json"

# Keep metadata outside the payload.  This makes the payload hash exact and
# lets a verifier authenticate the bytes before any extraction is attempted.
rm -f -- "$BUNDLE" "$MANIFEST"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  --exclude='./manifest.json' -C "$SOURCE" -czf "$BUNDLE" .
BUNDLE_SHA256="$(sha256sum "$BUNDLE" | awk '{print tolower($1)}')"
BUNDLE_BYTES="$(wc -c <"$BUNDLE" | tr -d ' ')"
EXTRACTED_BYTES="$(du -sb "$SOURCE" | awk '{print $1}')"
# A generation needs its extracted bytes, the incoming archive, and a small
# journal/rename reserve.  Round up to 4 KiB for OpenWrt filesystems.
MIN_SPACE_BYTES="$(( (EXTRACTED_BYTES + BUNDLE_BYTES + 4194304 + 4095) / 4096 * 4096 ))"

NODE_VERSION="$(sed -n '1p' "$SOURCE/node-version" | tr -d '[:space:]')"
MULTICA_VERSION="$(sed -n 's/^MULTICA_VERSION="${MULTICA_VERSION:-\([0-9.]*\)}".*/\1/p' "$ROOT_DIR/Scripts/fetch_multica_runtime.sh" | head -n1)"
UV_VERSION="$(sed -n 's/^UV_VERSION="\([0-9.]*\)".*/\1/p' "$ROOT_DIR/Scripts/fetch_uv_runtime.sh" | head -n1)"
PYTHON_VERSION="$(sed -n 's/^PYTHON_VERSION="\([0-9.]*\)".*/\1/p' "$ROOT_DIR/Scripts/fetch_uv_runtime.sh" | head -n1)"
PYTHON_RELEASE_TAG="$(sed -n 's/^PYTHON_RELEASE_TAG="\([0-9]*\)".*/\1/p' "$ROOT_DIR/Scripts/fetch_uv_runtime.sh" | head -n1)"
[ -n "$NODE_VERSION" ] && [ -n "$MULTICA_VERSION" ] && [ -n "$UV_VERSION" ] && [ -n "$PYTHON_VERSION" ] && [ -n "$PYTHON_RELEASE_TAG" ] || die "unable to read pinned runtime contract"

case "${NODE_VERSION%%.*}" in
	24) NODE_ABI=137 ;;
	22) NODE_ABI=127 ;;
	*) die "unreviewed Node version/ABI contract: $NODE_VERSION" ;;
esac
case "${NODE_VERSION%%.*}:$NODE_ABI" in 24:137|22:127) ;; *) die "unreviewed Node version/ABI contract: $NODE_VERSION/$NODE_ABI" ;; esac

# The catalog deliberately uses latest-at-build selectors.  The generation
# carries the exact package/lock/peer-alignment metadata that was resolved and
# verified for this build, so the signed manifest describes real bytes rather
# than a stale repository lock.
CATALOG_FILE="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
PACKAGES_JSON="$SOURCE/node/agent-runtime-package.json"
LOCK_FILE="$SOURCE/node/agent-runtime-package-lock.json"
RESOLVED_FILE="$SOURCE/node/agent-runtime-resolved.json"
SOURCE="$SOURCE" MANIFEST="$MANIFEST" ARCH="$ARCH" RUNTIME_RELEASE="$RUNTIME_RELEASE" \
  BUNDLE_SHA256="$BUNDLE_SHA256" BUNDLE_BYTES="$BUNDLE_BYTES" MIN_SPACE_BYTES="$MIN_SPACE_BYTES" \
  NODE_VERSION="$NODE_VERSION" NODE_ABI="$NODE_ABI" MULTICA_VERSION="$MULTICA_VERSION" UV_VERSION="$UV_VERSION" PYTHON_VERSION="$PYTHON_VERSION" PYTHON_RELEASE_TAG="$PYTHON_RELEASE_TAG" \
  CATALOG_FILE="$CATALOG_FILE" LOCK_FILE="$LOCK_FILE" PACKAGES_JSON="$PACKAGES_JSON" RESOLVED_FILE="$RESOLVED_FILE" \
  node <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const e = process.env;
const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const resolved = JSON.parse(fs.readFileSync(e.RESOLVED_FILE, 'utf8'));
const packages = resolved.components;
if (!packages || typeof packages !== 'object' || !/^\d+\.\d+\.\d+(?:[-+].*)?$/.test(resolved.pi_version || '')) {
  throw new Error('invalid resolved Pi extension metadata');
}
const piPlanMode = JSON.parse(fs.readFileSync(path.join(e.SOURCE, 'vendor/pi-plan-mode/provenance.json'), 'utf8'));
const releaseInputs = [
  e.CATALOG_FILE,
  e.PACKAGES_JSON,
  e.LOCK_FILE,
  e.RESOLVED_FILE,
  path.join(e.SOURCE, 'vendor/pi-plan-mode/provenance.json'),
  path.join(e.SOURCE, 'vendor/pi-plan-mode/plan-mode.ts'),
  path.join(path.dirname(e.CATALOG_FILE), 'runtime-release'),
  path.join(path.dirname(path.dirname(e.CATALOG_FILE)), 'fetch_multica_runtime.sh'),
  path.join(path.dirname(path.dirname(e.CATALOG_FILE)), 'fetch_uv_runtime.sh')
];
const inputHash = crypto.createHash('sha256');
for (const file of releaseInputs) inputHash.update(fs.readFileSync(file));
const criticalCandidates = [
  'node/bin/node', 'uv/uv', 'bin/multica',
  'node/lib/node_modules/command-code/dist/index.mjs',
  'vendor/pi-plan-mode/provenance.json'
];
const critical_elf_sha256 = {};
for (const rel of criticalCandidates) {
  const file = path.join(e.SOURCE, rel);
  if (fs.existsSync(file) && fs.statSync(file).isFile()) critical_elf_sha256[rel] = sha256(file);
}
const manifest = {
  schema_version: 1,
  runtime_release: Number(e.RUNTIME_RELEASE),
  architecture: e.ARCH,
  libc: 'musl',
  bundle: {
    filename: `agent-runtime-${e.RUNTIME_RELEASE}-${e.ARCH}-musl.tar.gz`,
    sha256: e.BUNDLE_SHA256,
    bytes: Number(e.BUNDLE_BYTES)
  },
  minimum_space_bytes: Number(e.MIN_SPACE_BYTES),
  runtime_contract: {
    node_version: e.NODE_VERSION,
    node_abi: Number(e.NODE_ABI),
    uv_version: e.UV_VERSION,
    python_series: '3.13',
    python_version: e.PYTHON_VERSION,
    python_release_tag: e.PYTHON_RELEASE_TAG
  },
  components: { ...packages, multica: e.MULTICA_VERSION, uv: e.UV_VERSION, cpython: e.PYTHON_VERSION, 'pi-plan-mode': piPlanMode.version },
  vendored_extensions: { 'pi-plan-mode': piPlanMode },
  lock_sha256: sha256(e.LOCK_FILE),
  input_sha256: inputHash.digest('hex'),
  critical_elf_sha256
};
fs.writeFileSync(e.MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 });
NODE

printf 'bundle=%s\nmanifest=%s\nsha256=%s\n' "$BUNDLE" "$MANIFEST" "$BUNDLE_SHA256"
