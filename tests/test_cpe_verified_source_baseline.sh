#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPE_WORKFLOW="$ROOT_DIR/.github/workflows/CPE-5G.yml"
CORE_WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
QCA_WORKFLOW="$ROOT_DIR/.github/workflows/QCA-6.18-VIKINGYFY.yml"
VERIFIED_SOURCE_SHA='42a1f64b5dbd2a99d05daca94ae5a87eebff59b4'

grep -q "WRT_COMMIT: $VERIFIED_SOURCE_SHA" "$CPE_WORKFLOW" || {
  echo "CPE-5G does not pin the verified firmware source commit"
  exit 1
}

grep -A4 '^      WRT_COMMIT:' "$CORE_WORKFLOW" | grep -q 'type: string' || {
  echo "WRT-CORE does not declare the optional WRT_COMMIT string input"
  exit 1
}

grep -q '^  WRT_COMMIT: \${{inputs.WRT_COMMIT}}$' "$CORE_WORKFLOW" || {
  echo "WRT-CORE does not export the WRT_COMMIT input"
  exit 1
}

grep -Eq 'git .*fetch.*WRT_COMMIT' "$CORE_WORKFLOW" || {
  echo "WRT-CORE does not fetch the requested immutable source commit"
  exit 1
}

grep -q 'git checkout --detach.*WRT_COMMIT' "$CORE_WORKFLOW" || {
  echo "WRT-CORE does not checkout the requested source commit detached"
  exit 1
}

grep -q 'git rev-parse HEAD' "$CORE_WORKFLOW" || {
  echo "WRT-CORE does not resolve and verify the checked out source commit"
  exit 1
}

if grep -q "$VERIFIED_SOURCE_SHA" "$QCA_WORKFLOW"; then
  echo "ordinary QCA 6.18 builds must not inherit the CPE-only source pin"
  exit 1
fi

echo "CPE verified source baseline test passed"
