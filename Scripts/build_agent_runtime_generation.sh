#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build one portable generation root from the same pinned fetchers used by a
# firmware build.  This is intentionally a CI-only staging tool: it never
# modifies files/ or wrt/files in the working tree.
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ARCH="" OUTPUT=""
die() { printf 'ERROR: [agent-runtime generation] %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ARCH" ] && [ -n "$OUTPUT" ] || die "--arch and --output are required"
case "$ARCH" in
  arm64) WRT_ARCH=aarch64; NODE_TARGET_ARCH=linux-arm64-musl; MULTICA_ARCH=arm64 ;;
  x64) WRT_ARCH=x86_64; NODE_TARGET_ARCH=linux-x64-musl; MULTICA_ARCH=amd64 ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

STAGE="$(mktemp -d)"
trap 'rm -rf -- "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/files"
export WRT_ARCH NODE_TARGET_ARCH MULTICA_ARCH
bash "$ROOT_DIR/Scripts/fetch_node_runtime.sh" "$STAGE/files"
bash "$ROOT_DIR/Scripts/fetch_multica_runtime.sh" "$STAGE/files"
bash "$ROOT_DIR/Scripts/finalize_agent_runtime_baseline.sh" "$STAGE/files"

rm -rf -- "$OUTPUT"
mkdir -p "$OUTPUT/bin"
cp -a "$STAGE/files/opt/node" "$OUTPUT/node"
install -m 0755 "$STAGE/files/usr/local/bin/multica" "$OUTPUT/bin/multica"
install -m 0644 "$STAGE/files/etc/agent-runtime/node-version" "$OUTPUT/node-version"
mkdir -p "$OUTPUT/vendor"
cp -a "$ROOT_DIR/Scripts/node-agent-runtime/vendor/pi-plan-mode" "$OUTPUT/vendor/pi-plan-mode"

# This is the fixed contract consumed by agent-runtime.  In particular, it
# does not retain legacy /opt/node or /data/node paths inside a generation.
[ -x "$OUTPUT/node/bin/node" ] || die "generation lacks node"
[ -x "$OUTPUT/bin/multica" ] || die "generation lacks multica"
[ -s "$OUTPUT/node-version" ] || die "generation lacks selected Node version metadata"
[ -s "$OUTPUT/vendor/pi-plan-mode/provenance.json" ] || die "generation lacks vendored Pi plan-mode provenance"
printf 'generation=%s\n' "$OUTPUT"
