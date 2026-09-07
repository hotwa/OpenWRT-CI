#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUMP_SCRIPT="$ROOT_DIR/Scripts/bump_agent_runtime.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/Agent-Runtime-Bump.yml"
POLICY_DOC="$ROOT_DIR/docs/agent-runtime-version-policy.md"
AGENTS_DOC="$ROOT_DIR/AGENTS.md"
NODE_FETCH="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
MULTICA_FETCH="$ROOT_DIR/Scripts/fetch_multica_runtime.sh"
UV_FETCH="$ROOT_DIR/Scripts/fetch_uv_runtime.sh"
CORE_WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
PACKAGE_JSON="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
PEER_RESOLVER="$ROOT_DIR/Scripts/ensure_pi_extension_peers.js"
EXTENSION_VERIFIER="$ROOT_DIR/Scripts/verify_pi_extensions.js"
RUNTIME_RELEASE_FILE="$ROOT_DIR/Scripts/node-agent-runtime/runtime-release"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

fail() { echo "agent runtime policy: $*" >&2; exit 1; }
for path in "$BUMP_SCRIPT" "$WORKFLOW" "$POLICY_DOC" "$AGENTS_DOC" "$NODE_FETCH" "$MULTICA_FETCH" "$UV_FETCH" "$CORE_WORKFLOW" "$PACKAGE_JSON" "$PEER_RESOLVER" "$EXTENSION_VERIFIER" "$RUNTIME_RELEASE_FILE"; do
  [ -f "$path" ] || fail "missing $path"
done
bash -n "$BUMP_SCRIPT"

for term in 'CommandCode' 'Pi' 'Multica' 'Node.js' 'CPython 3.13'; do
  grep -Fq "$term" "$POLICY_DOC" || fail "policy omits $term"
done
for retired in 'build_hermes_core.sh' 'opencode-ai' 'hermes-agent'; do
  if grep -Fq "$retired" "$BUMP_SCRIPT" "$WORKFLOW" "$NODE_FETCH" "$POLICY_DOC"; then
    fail "retired runtime reference survives: $retired"
  fi
done
grep -Fq 'fetch_uv_runtime.sh' "$CORE_WORKFLOW" || fail "firmware workflow must stage the pinned uv bootstrap"
UV_LINE="$(grep -n 'Scripts/fetch_uv_runtime.sh' "$CORE_WORKFLOW" | head -n1 | cut -d: -f1)"
NODE_LINE="$(grep -n 'Scripts/fetch_node_runtime.sh' "$CORE_WORKFLOW" | head -n1 | cut -d: -f1)"
MULTICA_LINE="$(grep -n 'Scripts/fetch_multica_runtime.sh' "$CORE_WORKFLOW" | head -n1 | cut -d: -f1)"
[ -n "$UV_LINE" ] && [ -n "$NODE_LINE" ] && [ -n "$MULTICA_LINE" ] && [ "$UV_LINE" -lt "$NODE_LINE" ] && [ "$NODE_LINE" -lt "$MULTICA_LINE" ] || fail "WRT-CORE must prepare uv, Node, then Multica"

for command in pi cmdc command-code commandcode; do
  grep -Fq "$command" "$NODE_FETCH" || fail "runtime staging omits $command"
done
grep -Fq 'latest-at-build' "$POLICY_DOC" || fail "policy does not describe latest-at-build Pi/plugin resolution"
grep -Fq 'verify_pi_extensions.js' "$WORKFLOW" || fail "release workflow does not import-check Pi extensions"
grep -Fq 'advance-release' "$WORKFLOW" || fail "release workflow does not advance an immutable runtime sequence"

echo "agent runtime policy tests passed"
