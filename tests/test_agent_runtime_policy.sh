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
RUNTIME_RELEASE_FILE="$ROOT_DIR/Scripts/node-agent-runtime/runtime-release"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

fail() { echo "agent runtime policy: $*" >&2; exit 1; }
for path in "$BUMP_SCRIPT" "$WORKFLOW" "$POLICY_DOC" "$AGENTS_DOC" "$NODE_FETCH" "$MULTICA_FETCH" "$UV_FETCH" "$CORE_WORKFLOW" "$PACKAGE_JSON" "$RUNTIME_RELEASE_FILE"; do
  [ -f "$path" ] || fail "missing $path"
done
bash -n "$BUMP_SCRIPT"
grep -Fq 'bash "$PI_PLAN_VENDOR_SCRIPT" apply "$latest"' "$BUMP_SCRIPT" ||
  fail "agent bump must invoke the Pi vendor refresher through bash"
grep -Fq 'bash "$PI_PLAN_VENDOR_SCRIPT" plan' "$BUMP_SCRIPT" ||
  fail "agent bump must invoke the Pi vendor validation through bash"

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
  grep -Fq "$command" "$BUMP_SCRIPT" || fail "cross-target verification omits $command"
done

# npm returns a nested `dist` object only when asked for `dist`; asking for
# `dist.integrity` instead creates a flattened key and makes the bump job fail
# before it can decide whether the vendored extension needs refreshing.
FAKE_NPM_DIR="$WORK_DIR/fake-npm"
FAKE_NPM_LOG="$WORK_DIR/npm.args"
mkdir -p "$FAKE_NPM_DIR"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\\n" "$*" > "$TEST_NPM_LOG"' \
  'printf "%s\\n" '\''{"version":"0.4.8","dist":{"integrity":"sha512-test=="}}'\''' \
  >"$FAKE_NPM_DIR/npm"
chmod 755 "$FAKE_NPM_DIR/npm"
(
  export PATH="$FAKE_NPM_DIR:$PATH"
  export TEST_NPM_LOG="$FAKE_NPM_LOG"
  # shellcheck disable=SC1090
  . <(sed '/^main "\$@"$/d' "$BUMP_SCRIPT")
  pi_plan_vendor_latest
) >"$WORK_DIR/pi-plan-latest"
[ "$(cat "$WORK_DIR/pi-plan-latest")" = $'0.4.8\tsha512-test==' ] || fail "pi-plan vendor metadata parsing broke"
[ "$(cat "$FAKE_NPM_LOG")" = 'view pi-plan-mode version dist --json' ] || fail "pi-plan vendor query must request nested dist"

echo "agent runtime policy tests passed"
