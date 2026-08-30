#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/docs/agent-runtime-version-policy.md"
RELEASE="$ROOT_DIR/docs/agent-runtime-release.md"
AGENTS="$ROOT_DIR/AGENTS.md"
README="$ROOT_DIR/README.md"
WORKFLOW="$ROOT_DIR/.github/workflows/Agent-Runtime-Bump.yml"

fail() { echo "agent runtime docs policy: $*" >&2; exit 1; }
for path in "$POLICY" "$RELEASE" "$AGENTS" "$README" "$WORKFLOW"; do
  [ -f "$path" ] || fail "missing $path"
done

grep -Eq "cron: ['\"]?0 \* \* \* \*['\"]?" "$WORKFLOW" || fail "workflow is no longer hourly"
for term in 'Pi / CommandCode' '已签名的不可变 generation' 'Node.js' '固件不预置任何用户' '/data/node'; do
  grep -Fq "$term" "$POLICY" || fail "policy omits $term"
done
for term in 'CommandCode' 'Pi' 'Multica' 'generation'; do
  grep -Eqi "$term" "$RELEASE" "$AGENTS" "$README" || fail "runtime documentation omits $term"
done
for retired in 'OpenCode' 'Hermes' 'fetch_uv_runtime.sh' 'build_hermes_core.sh' 'Python 3.12 (`uv`)'; do
  if grep -Fq "$retired" "$POLICY" "$RELEASE" "$AGENTS" "$README"; then
    fail "current policy-facing documentation still advertises $retired"
  fi
done

echo "agent runtime documentation policy tests passed"
