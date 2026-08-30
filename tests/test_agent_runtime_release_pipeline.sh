#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/Agent-Runtime-Bump.yml"
PACKAGE="$ROOT_DIR/Scripts/package_agent_runtime_bundle.sh"
VERIFY="$ROOT_DIR/Scripts/verify_agent_runtime_bundle.sh"
INDEX="$ROOT_DIR/Scripts/write_agent_runtime_index.sh"
SIGN="$ROOT_DIR/Scripts/sign_agent_runtime_metadata.sh"
FINALIZE="$ROOT_DIR/Scripts/finalize_agent_runtime_baseline.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail() { echo "agent runtime release pipeline: $*" >&2; exit 1; }
for path in "$WORKFLOW" "$PACKAGE" "$VERIFY" "$INDEX" "$SIGN" "$FINALIZE"; do
  [ -f "$path" ] || fail "missing $path"
done
for path in "$PACKAGE" "$VERIFY" "$INDEX" "$SIGN" "$FINALIZE"; do
  bash -n "$path" || fail "$path does not parse"
done

grep -Eq "cron: ['\"]?0 \* \* \* \*['\"]?" "$WORKFLOW" || fail "workflow is not hourly"
for term in 'AGENT_RUNTIME_USIGN_SECRET_KEY' 'files/etc/agent-runtime/usign.pub' 'qemu-user-static' 'cmdc --version' 'Sign index and manifests'; do
  grep -Fq "$term" "$WORKFLOW" || fail "workflow omits $term"
done
if grep -Eqi 'HERMES_TARGET_RUNNER|opencode-dcp' "$WORKFLOW"; then
	fail "workflow still probes a retired runtime"
fi
grep -Fq 'uv --version' "$WORKFLOW" || fail "workflow does not probe the pinned uv runtime"

mkdir -p "$WORK/generation/node/bin" "$WORK/generation/uv/python-mirror" "$WORK/generation/bin" "$WORK/generation/vendor"
cp "$(command -v node)" "$WORK/generation/node/bin/node"
cp "$(command -v node)" "$WORK/generation/uv/uv"
printf 'python_series=3.13\n' > "$WORK/generation/uv/python-mirror/manifest.txt"
printf '#!/bin/sh\necho 0.4.35\n' > "$WORK/generation/bin/multica"
chmod 755 "$WORK/generation/node/bin/node" "$WORK/generation/bin/multica"
printf '24.20.0\n' > "$WORK/generation/node-version"
cp -a "$ROOT_DIR/Scripts/node-agent-runtime/vendor/pi-plan-mode" "$WORK/generation/vendor/pi-plan-mode"
bash "$PACKAGE" --source "$WORK/generation" --output "$WORK/release" --arch x64 --runtime-release 497 >/dev/null
MANIFEST="$WORK/release/agent-runtime-497-x64-musl.manifest.json"
BUNDLE="$WORK/release/agent-runtime-497-x64-musl.tar.gz"
bash "$VERIFY" --manifest "$MANIFEST" --bundle "$BUNDLE" >/dev/null
node - "$MANIFEST" <<'NODE'
const m = require(process.argv[2]);
for (const k of ['runtime_release', 'architecture', 'libc', 'bundle', 'minimum_space_bytes', 'runtime_contract', 'components', 'vendored_extensions', 'lock_sha256', 'critical_elf_sha256']) if (!(k in m)) process.exit(1);
if (m.architecture !== 'x64' || m.libc !== 'musl' || !m.components['command-code']) process.exit(2);
if (m.components['hermes-agent'] || m.components['opencode-ai']) process.exit(3);
NODE

mkdir -p "$WORK/firmware/files/opt/node/bin" "$WORK/firmware/files/opt/uv/python-mirror" "$WORK/firmware/files/etc/agent-runtime" "$WORK/firmware/files/usr/local/bin"
cp "$WORK/generation/node/bin/node" "$WORK/firmware/files/opt/node/bin/node"
cp "$WORK/generation/uv/uv" "$WORK/firmware/files/opt/uv/uv"
cp "$WORK/generation/uv/python-mirror/manifest.txt" "$WORK/firmware/files/opt/uv/python-mirror/manifest.txt"
cp "$WORK/generation/node-version" "$WORK/firmware/files/etc/agent-runtime/node-version"
cp "$WORK/generation/bin/multica" "$WORK/firmware/files/usr/local/bin/multica"
chmod 755 "$WORK/firmware/files/opt/node/bin/node" "$WORK/firmware/files/opt/uv/uv" "$WORK/firmware/files/usr/local/bin/multica"
GITHUB_WORKSPACE="$ROOT_DIR" AGENT_RUNTIME_RELEASE=497 bash "$FINALIZE" "$WORK/firmware/files" >/dev/null
node - "$WORK/firmware/files/opt/agent-runtime/manifest.json" <<'NODE'
const m = require(process.argv[2]);
if (m.architecture !== 'x64' || m.runtime_release !== 497 || !m.components['command-code'] || m.runtime_contract.python_series !== '3.13') process.exit(1);
if (m.components['hermes-agent'] || m.components['opencode-ai']) process.exit(2);
NODE

if bash "$SIGN" --public-key "$MANIFEST" --manifest "$MANIFEST" --index "$MANIFEST" >"$WORK/no-key.log" 2>&1; then
  fail "signer accepted a missing private key"
fi
grep -Fq 'AGENT_RUNTIME_USIGN_SECRET_KEY is required' "$WORK/no-key.log" || fail "missing-key error is not explicit"

echo "agent runtime release pipeline tests passed"
