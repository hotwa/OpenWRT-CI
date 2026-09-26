#!/usr/bin/env bash
# Non-publishing, no-secret CNB runner compatibility probe. No network/device calls.
set -euo pipefail

# CNB provides a short-lived repository token by default. These guards need no token.
unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
printf 'runner architecture: %s\n' "$(uname -m)"
printf 'runner kernel: %s\n' "$(uname -s)"
printf 'runner CPUs: %s\n' "$(nproc)"
printf 'runner disk: '; df -h . | tail -n 1
if command -v free >/dev/null 2>&1; then
  printf 'runner memory:\n'
  free -h | head -n 2
fi
if command -v git >/dev/null 2>&1; then
  printf 'repository commit: %s\n' "$(git rev-parse HEAD)"
fi

# Short, source-controlled guards only. A successful probe is NOT a firmware build.
for test_script in \
  tests/test_wrt_cache_identity.sh \
  tests/test_re_cs_07_workflow.sh \
  tests/test_ci_workflow_boundaries.sh; do
  printf 'running %s\n' "$test_script"
  bash "$test_script"
done
printf 'CNB shadow runner probe passed (no firmware built or deployed)\n'
