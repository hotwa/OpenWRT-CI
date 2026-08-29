#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/CI-DEBUG-SSH-TEST.yml"

fail() {
  echo "CI Debug SSH workflow contract failed: $*" >&2
  exit 1
}

[ -f "$WORKFLOW" ] || fail "workflow is missing"

has_fixed() {
  if command -v rg >/dev/null 2>&1; then
    rg -Fq -- "$1" "$WORKFLOW"
  else
    grep -Fq -- "$1" "$WORKFLOW"
  fi
}

has_regex() {
  if command -v rg >/dev/null 2>&1; then
    rg -q -- "$1" "$WORKFLOW"
  else
    grep -Eq -- "$1" "$WORKFLOW"
  fi
}

has_regex '^name: CI Debug SSH Smoke$' || fail "workflow name is missing"
has_regex '^  workflow_dispatch:$' || fail "workflow_dispatch trigger is missing"
has_regex '^      hold_minutes:$' || fail "hold_minutes input is missing"
has_regex '^        type: number$' || fail "hold_minutes must be numeric"
has_regex '^        default: 30$' || fail "default hold must be 30 minutes"
has_regex 'HOLD_MINUTES < 1 \|\| HOLD_MINUTES > 90' || fail "1-90 hold bound is missing"
has_regex '^    runs-on: ubuntu-latest$' || fail "runner must be ubuntu-latest"
has_regex '^    timeout-minutes: 100$' || fail "job timeout is missing"
has_fixed 'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803' || fail "checkout SHA is not pinned to the repository version"

has_fixed 'permissions:' || fail "permissions block is missing"
has_fixed 'contents: read' || fail "contents read permission is missing"
has_fixed 'group: ci-debug-ssh-smoke' || fail "concurrency group is missing"
has_fixed 'cancel-in-progress: true' || fail "duplicate smoke cancellation is missing"

has_fixed 'HEADSCALE_AUTHKEY: ${{ secrets.HEADSCALE_CI_AUTHKEY }}' || fail "CI auth-key secret mapping is missing"
has_fixed 'HEADSCALE_LOGIN: ${{ secrets.HEADSCALE_URL }}' || fail "Headscale URL secret mapping is missing"
has_fixed 'HEADSCALE_CI_AUTHKEY is missing' || fail "missing auth-key must fail explicitly"
has_fixed 'HEADSCALE_URL is missing' || fail "missing URL must fail explicitly"

has_fixed 'bash "$GITHUB_WORKSPACE/Scripts/setup_ci_tailscale.sh"' || fail "setup must be invoked through bash"
has_fixed 'CI_DEBUG_ENV_FILE' || fail "same-step environment file is missing"
has_fixed 'source "$DEBUG_ENV_FILE"' || fail "same-step environment file is not sourced"
has_fixed 'Enrolled IP:' || fail "enrolled IP output is missing"
has_fixed 'MagicDNS name:' || fail "MagicDNS output is missing"
has_fixed 'ci-debug-' || fail "ci-debug hostname contract is missing"
has_fixed 'touch /tmp/continue-ci' || fail "remote release command is missing"
has_fixed 'while [ ! -e /tmp/continue-ci ]' || fail "hold loop is missing"
has_fixed 'Hold timeout reached; releasing runner safely' || fail "safe timeout release is missing"
has_fixed 'sudo kill "$CI_TSCALE_PID"' || fail "targeted tailscaled cleanup is missing"
has_fixed 'sudo rm -f /run/tailscaled-tmp.state' || fail "temporary state cleanup is missing"
has_fixed 'trap cleanup EXIT' || fail "cleanup trap is missing"

echo "CI Debug SSH workflow contract test passed"
