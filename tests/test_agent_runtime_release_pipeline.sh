#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/Agent-Runtime-Bump.yml"
PACKAGE="$ROOT_DIR/Scripts/package_agent_runtime_bundle.sh"
VERIFY="$ROOT_DIR/Scripts/verify_agent_runtime_bundle.sh"
INDEX="$ROOT_DIR/Scripts/write_agent_runtime_index.sh"
SIGN="$ROOT_DIR/Scripts/sign_agent_runtime_metadata.sh"
PUBLISH="$ROOT_DIR/Scripts/publish_agent_runtime_release.sh"
BUILD="$ROOT_DIR/Scripts/build_agent_runtime_generation.sh"
FINALIZE="$ROOT_DIR/Scripts/finalize_agent_runtime_baseline.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail() { echo "agent runtime release pipeline: $*" >&2; exit 1; }
for path in "$WORKFLOW" "$PACKAGE" "$VERIFY" "$INDEX" "$SIGN" "$PUBLISH" "$BUILD" "$FINALIZE"; do
  [ -f "$path" ] || fail "missing $path"
done
for path in "$PACKAGE" "$VERIFY" "$INDEX" "$SIGN" "$PUBLISH" "$BUILD" "$FINALIZE"; do
  bash -n "$path" || fail "$path does not parse"
done

grep -Eq "cron: ['\"]?0 \* \* \* \*['\"]?" "$WORKFLOW" || fail "workflow is not hourly"
grep -q 'AGENT_RUNTIME_USIGN_SECRET_KEY' "$WORKFLOW" || fail "workflow does not require the usign signing secret"
grep -q 'files/etc/agent-runtime/usign.pub' "$WORKFLOW" || fail "workflow does not bind signatures to the firmware public key"
grep -q 'finalize_agent_runtime_baseline.sh' "$ROOT_DIR/.github/workflows/WRT-CORE.yml" || fail "firmware build does not finalize the immutable baseline"
grep -q 'force_release' "$WORKFLOW" || fail "workflow cannot bootstrap the first signed release"
grep -q 'agent-runtime-stable' "$WORKFLOW" || fail "workflow does not publish a stable runtime-only channel"
grep -q 'only the fixed agent-runtime-stable tag may be published' "$PUBLISH" || fail "publisher permits mutable release tags"
grep -q 'input_sha256' "$PACKAGE" || fail "bundle manifest cannot identify the complete release inputs"
grep -q 'qemu-user-static' "$WORKFLOW" || fail "workflow does not prepare arm64 musl probing"
grep -q 'HERMES_TARGET_RUNNER=qemu-aarch64' "$WORKFLOW" || fail "workflow does not fail closed through QEMU for arm64 Hermes Core"
grep -q 'opencode-dcp' "$WORKFLOW" || fail "workflow does not probe DCP"
grep -q 'Sign index and manifests' "$WORKFLOW" || fail "workflow does not sign both index and manifests"
PUSH_LINE="$(grep -n 'git push' "$WORKFLOW" | head -n1 | cut -d: -f1)"
PUBLISH_LINE="$(grep -n 'Publish signed complete stack release' "$WORKFLOW" | head -n1 | cut -d: -f1)"
[ "$PUSH_LINE" -lt "$PUBLISH_LINE" ] || fail "stable channel can publish ahead of the committed pins"
grep -q 'incomplete signed' "$WORKFLOW" || fail "workflow has no partial-publication recovery path"

mkdir -p "$WORK/generation/node/bin" "$WORK/generation/node/lib/node_modules" "$WORK/generation/uv" "$WORK/generation/bin" "$WORK/generation/vendor/pi-plan-mode"
printf '#!/bin/sh\nexit 0\n' > "$WORK/generation/node/bin/node"
printf '#!/bin/sh\nexit 0\n' > "$WORK/generation/bin/multica"
chmod 755 "$WORK/generation/node/bin/node" "$WORK/generation/bin/multica"
printf 'uv fixture\n' > "$WORK/generation/uv/uv"
printf '24.20.0\n' > "$WORK/generation/node-version"
printf '{"component":"hermes-core","npm_version":"0.20.6","lock_sha256":"fixture","node_abi":"137","architecture":"arm64"}\n' > "$WORK/generation/hermes-core.json"
printf '{"package":"pi-plan-mode","version":"0.4.8","source_sha256":"fixture"}\n' > "$WORK/generation/vendor/pi-plan-mode/provenance.json"
bash "$PACKAGE" --source "$WORK/generation" --output "$WORK/release" --arch arm64 --runtime-release 42 >/dev/null
MANIFEST="$WORK/release/agent-runtime-42-arm64-musl.manifest.json"
BUNDLE="$WORK/release/agent-runtime-42-arm64-musl.tar.gz"
bash "$VERIFY" --manifest "$MANIFEST" --bundle "$BUNDLE" >/dev/null
node - "$MANIFEST" <<'NODE'
const m = require(process.argv[2]);
for (const k of ['runtime_release', 'architecture', 'libc', 'bundle', 'minimum_space_bytes', 'runtime_contract', 'components', 'hermes_core', 'lock_sha256', 'critical_elf_sha256']) if (!(k in m)) process.exit(1);
if (m.runtime_release !== 42 || m.architecture !== 'arm64' || m.libc !== 'musl') process.exit(2);
if (!Number.isInteger(m.runtime_contract.node_abi) || !Array.isArray(m.runtime_contract.cpython_series)) process.exit(3);
if (m.components['hermes-core'] !== '0.20.6' || m.hermes_core.component !== 'hermes-core') process.exit(4);
NODE

mkdir -p "$WORK/firmware/files/opt/node/bin" "$WORK/firmware/files/opt/agent-runtime" \
  "$WORK/firmware/files/etc/agent-runtime" "$WORK/firmware/files/opt/uv" \
  "$WORK/firmware/files/usr/local/bin"
cp "$WORK/generation/node/bin/node" "$WORK/firmware/files/opt/node/bin/node"
cp "$WORK/generation/node-version" "$WORK/firmware/files/etc/agent-runtime/node-version"
cp "$WORK/generation/hermes-core.json" "$WORK/firmware/files/opt/agent-runtime/hermes-core.json"
cp -a "$WORK/generation/uv/." "$WORK/firmware/files/opt/uv/"
cp "$WORK/generation/bin/multica" "$WORK/firmware/files/usr/local/bin/multica"
chmod 755 "$WORK/firmware/files/opt/node/bin/node" "$WORK/firmware/files/usr/local/bin/multica"
GITHUB_WORKSPACE="$ROOT_DIR" AGENT_RUNTIME_RELEASE=42 bash "$FINALIZE" \
  "$WORK/firmware/files" >/dev/null
FINALIZED="$WORK/firmware/files/opt/agent-runtime/manifest.json"
node - "$FINALIZED" <<'NODE'
const m = require(process.argv[2]);
for (const k of ['schema_version', 'runtime_release', 'architecture', 'libc', 'runtime_contract', 'components', 'hermes_core', 'vendored_extensions', 'critical_elf_sha256']) if (!(k in m)) process.exit(1);
if (m.schema_version !== 1 || m.runtime_release !== 42 || m.architecture !== 'arm64' || m.libc !== 'musl') process.exit(2);
if (m.runtime_contract.node_version !== '24.20.0' || m.runtime_contract.node_abi !== 137) process.exit(3);
if (m.components['pi-plan-mode'] !== '0.4.8' || m.hermes_core.component !== 'hermes-core') process.exit(4);
const provenance = m.vendored_extensions['pi-plan-mode'];
if (!provenance.source_sha256 || typeof provenance.source_sha256 !== 'object') process.exit(5);
if (!/^[a-f0-9]{64}$/.test(provenance.source_sha256['package.json'])) process.exit(6);
if (!/^[a-f0-9]{64}$/.test(m.critical_elf_sha256['node/bin/node'])) process.exit(7);
NODE

# The current finalized manifest intentionally uses `architecture`; jsonfilter
# returns success for a missing legacy `arch` path, so the compatibility check
# must fall back on empty output rather than shell status alone.
MANAGER="$ROOT_DIR/files/usr/sbin/agent-runtime"
RUNTIME_FIXTURE="$WORK/runtime-health"
mkdir -p "$RUNTIME_FIXTURE/node/bin" "$RUNTIME_FIXTURE/uv" "$RUNTIME_FIXTURE/bin"
printf '#!/bin/sh\nprintf "137\\n"\n' >"$RUNTIME_FIXTURE/node/bin/node"
printf '#!/bin/sh\nexit 0\n' >"$RUNTIME_FIXTURE/uv/uv"
printf '#!/bin/sh\nexit 0\n' >"$RUNTIME_FIXTURE/bin/multica"
chmod 755 "$RUNTIME_FIXTURE/node/bin/node" "$RUNTIME_FIXTURE/uv/uv" "$RUNTIME_FIXTURE/bin/multica"
cat >"$RUNTIME_FIXTURE/manifest.json" <<'EOF'
{"architecture":"arm64","libc":"musl","runtime_contract":{"node_abi":137}}
EOF
sed '/^case "\$#" in$/,$d' "$MANAGER" >"$WORK/agent-runtime-lib.sh"
(
  set -u
  AGENT_RUNTIME_BASELINE="$RUNTIME_FIXTURE"
  # shellcheck disable=SC1090
  . "$WORK/agent-runtime-lib.sh"
  machine_arch() { printf '%s' arm64; }
  jsonfilter() {
    case "${4:-}" in
      '@.arch') return 0 ;;
      '@.architecture') printf '%s\n' arm64 ;;
      '@.libc') printf '%s\n' musl ;;
      '@.runtime_contract.node_abi') printf '%s\n' 137 ;;
      *) return 1 ;;
    esac
  }
  manifest_compatible "$RUNTIME_FIXTURE"
) || fail "agent-runtime rejects a canonical architecture-only manifest"

cp -a "$WORK/generation" "$WORK/generation-x64"
sed -i 's/"architecture":"arm64"/"architecture":"x64"/' "$WORK/generation-x64/hermes-core.json"
bash "$PACKAGE" --source "$WORK/generation-x64" --output "$WORK/release" --arch x64 --runtime-release 42 >/dev/null
bash "$INDEX" --directory "$WORK/release" --tag agent-runtime-42 >/dev/null
node - "$WORK/release/index.json" <<'NODE'
const i = require(process.argv[2]);
if (i.runtime_release !== 42 || !i.releases.arm64 || !i.releases.x64) process.exit(1);
NODE

if bash "$SIGN" --public-key "$MANIFEST" --manifest "$MANIFEST" --index "$MANIFEST" >"$WORK/no-key.log" 2>&1; then
  fail "signer accepted a missing private key"
fi
grep -q 'AGENT_RUNTIME_USIGN_SECRET_KEY is required' "$WORK/no-key.log" || fail "missing-key error is not explicit"

echo "agent runtime release pipeline tests passed"
