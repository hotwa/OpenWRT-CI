#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow-discovery.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTO_CLEAN="$ROOT_DIR/.github/workflows/Auto-Clean.yml"
WRT_CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$AUTO_CLEAN" ] || { echo "missing Auto-Clean workflow"; exit 1; }
[ -f "$WRT_CORE" ] || { echo "missing WRT-CORE workflow"; exit 1; }

for workflow in $(discover_device_workflows); do
  if grep -q "cron:" "$workflow"; then
    echo "$(basename "$workflow") workflow still has a scheduled build"
    exit 1
  fi

  if grep -q "workflow_run:" "$workflow"; then
    echo "$(basename "$workflow") workflow still has a workflow_run trigger"
    exit 1
  fi

  grep -q "secrets: inherit" "$workflow" || {
    echo "$(basename "$workflow") workflow does not pass secrets into WRT-CORE"
    exit 1
  }
done

grep -q "Scripts/HeadscaleAutoEnroll.sh" "$WRT_CORE" || {
  echo "WRT-CORE does not inject Headscale auto-enroll settings"
  exit 1
}

if grep -q "TARGET_PREFIX='QCA-6.18-VIKINGYFY-AUTO-'" "$AUTO_CLEAN"; then
  echo "Auto-Clean still targets QCA-6.18 auto-build releases"
  exit 1
fi

if grep -q "TARGET_PREFIX='QCA-6.12-VIKINGYFY-AUTO-'" "$AUTO_CLEAN"; then
  echo "Auto-Clean still targets QCA-6.12 auto-build releases"
  exit 1
fi

echo "QCA-6.18 manual-only build trigger test passed"
