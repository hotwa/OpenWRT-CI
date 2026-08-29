#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify the unsigned structural invariants before usign verification/extract.
set -euo pipefail

BUNDLE="" MANIFEST=""
die() { printf 'ERROR: [agent-runtime verify] %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -r "$BUNDLE" ] && [ -r "$MANIFEST" ] || die "--bundle and --manifest must name readable files"
actual="$(sha256sum "$BUNDLE" | awk '{print tolower($1)}')"
expected="$(node -e 'const m=require(process.argv[1]); process.stdout.write(m.bundle.sha256)' "$MANIFEST")" || die "invalid manifest JSON"
[ "$actual" = "$expected" ] || die "bundle SHA256 mismatch"
node - "$MANIFEST" <<'NODE'
const m = require(process.argv[2]);
const need = ['schema_version', 'runtime_release', 'architecture', 'libc', 'bundle', 'minimum_space_bytes', 'runtime_contract', 'components', 'hermes_core', 'vendored_extensions', 'lock_sha256', 'input_sha256', 'critical_elf_sha256'];
for (const k of need) if (!(k in m)) throw new Error(`missing ${k}`);
if (m.schema_version !== 1 || !Number.isSafeInteger(m.runtime_release) || m.runtime_release < 1) throw new Error('invalid release');
if (!['arm64', 'x64'].includes(m.architecture) || m.libc !== 'musl') throw new Error('invalid platform');
if (!/^[a-f0-9]{64}$/.test(m.bundle.sha256) || !/^[a-f0-9]{64}$/.test(m.lock_sha256) || !/^[a-f0-9]{64}$/.test(m.input_sha256)) throw new Error('invalid SHA256');
if (!Number.isSafeInteger(m.runtime_contract.node_abi) || !Array.isArray(m.runtime_contract.cpython_series)) throw new Error('invalid runtime contract');
if (!m.hermes_core || String(m.hermes_core.node_abi) !== String(m.runtime_contract.node_abi)) throw new Error('invalid Hermes Core contract');
if (!m.vendored_extensions['pi-plan-mode'] || m.components['pi-plan-mode'] !== m.vendored_extensions['pi-plan-mode'].version) throw new Error('invalid vendored Pi plan-mode contract');
NODE

# Do not extract before rejecting archive traversal, absolute paths, or device
# nodes.  agent-runtime repeats these checks on-device before staging.
tar -tzf "$BUNDLE" | awk '
  /^\// || /^\.\.($|\/)/ || /\/\.\.?(\/|$)/ { bad=1 }
  END { exit bad }
' || die "unsafe path in bundle"
tar -tvzf "$BUNDLE" | awk '$1 ~ /^[bcp]/ { bad=1 } END { exit bad }' || die "bundle contains device/FIFO entries"
printf 'verified %s\n' "$BUNDLE"
