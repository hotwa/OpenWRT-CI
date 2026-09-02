#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/Auto-Clean.yml"

fail() { echo "auto-clean: $*" >&2; exit 1; }

[ -f "$WORKFLOW" ] || fail "missing Auto-Clean workflow"

for term in \
  'Delete completed failed workflow runs' \
  'status=completed&per_page=100' \
  '.conclusion == "failure"' \
  '.conclusion == "timed_out"' \
  '.conclusion == "startup_failure"' \
  '.conclusion == "action_required"' \
  '.conclusion == "cancelled"' \
  'gh api --method DELETE' \
  'workflows_keep_day: 30'; do
  grep -Fq "$term" "$WORKFLOW" || fail "missing $term"
done

echo "auto-clean test passed"
