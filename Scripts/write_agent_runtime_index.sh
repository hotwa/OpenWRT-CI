#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Produce the release index only after both manifests/bundles have passed
# structural verification.  URLs are relative assets so a device can resolve
# them against /etc/agent-runtime/release-url without accepting arbitrary URLs.
set -euo pipefail

DIRECTORY="" TAG=""
die() { printf 'ERROR: [agent-runtime index] %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --directory) DIRECTORY="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$DIRECTORY" ] && [ -n "$TAG" ] || die "--directory and --tag are required"
DIRECTORY="$(realpath -e "$DIRECTORY")"
for arch in arm64 x64; do
  manifest="$(find "$DIRECTORY" -maxdepth 1 -type f -name "agent-runtime-*-${arch}-musl.manifest.json" -print -quit)"
  [ -n "$manifest" ] || die "missing $arch manifest"
  bundle="${manifest%.manifest.json}.tar.gz"
  [ -r "$bundle" ] || die "missing $arch bundle"
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify_agent_runtime_bundle.sh" --manifest "$manifest" --bundle "$bundle"
done

DIRECTORY="$DIRECTORY" TAG="$TAG" node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const dir = process.env.DIRECTORY;
const releases = {};
for (const arch of ['arm64', 'x64']) {
  const name = fs.readdirSync(dir).find(n => new RegExp(`^agent-runtime-[0-9]+-${arch}-musl\\.manifest\\.json$`).test(n));
  const m = JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
  releases[arch] = {
    runtime_release: m.runtime_release,
    libc: m.libc,
    manifest: name,
    manifest_signature: `${name}.sig`,
    bundle: m.bundle.filename,
    bundle_sha256: m.bundle.sha256,
    bundle_bytes: m.bundle.bytes,
    minimum_space_bytes: m.minimum_space_bytes,
    runtime_contract: m.runtime_contract
  };
}
if (releases.arm64.runtime_release !== releases.x64.runtime_release) throw new Error('architectures have different runtime_release values');
const index = { schema_version: 1, release_tag: process.env.TAG, runtime_release: releases.arm64.runtime_release, releases };
fs.writeFileSync(path.join(dir, 'index.json'), `${JSON.stringify(index, null, 2)}\n`, { mode: 0o644 });
NODE
