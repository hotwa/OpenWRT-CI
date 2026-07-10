#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/CPE-5G.yml"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
DOC="$ROOT_DIR/docs/cpe-5g-preset.md"

grep -q '^CONFIG_PACKAGE_luci-app-lucky=y$' "$GENERAL" || {
  echo "Lucky is not enabled in the shared firmware package selection"
  exit 1
}

[ -f "$WORKFLOW" ] || {
  echo "missing CPE-5G workflow preset"
  exit 1
}

grep -q "name: CPE-5G" "$WORKFLOW" || {
  echo "CPE-5G workflow has the wrong name"
  exit 1
}

grep -q "default: '192.168.13.1'" "$WORKFLOW" || {
  echo "CPE-5G workflow does not default to 192.168.13.1"
  exit 1
}

grep -q 'WRT_CONFIG: IPQ60XX-WIFI-YES' "$WORKFLOW" || {
  echo "CPE-5G workflow must build the IPQ60XX Wi-Fi profile"
  exit 1
}

grep -q 'WRT_PW:' "$WORKFLOW" || {
  echo "CPE-5G workflow must pass the required WRT_PW reusable input"
  exit 1
}

grep -q 'WRT_LAN_TAILNET: false' "$WORKFLOW" || {
  echo "CPE-5G workflow must keep LAN-to-tailnet forwarding disabled by default"
  exit 1
}

grep -q 'WRT_CPE_5G: true' "$WORKFLOW" || {
  echo "CPE-5G workflow must enable the CPE network bootstrap"
  exit 1
}

grep -A4 'WRT_CPE_5G:' "$CORE" | grep -q 'default: false' || {
  echo "reusable workflow must disable the CPE network bootstrap by default"
  exit 1
}

grep -q 'ConfigureCpe5G.sh.*WRT_CPE_5G' "$CORE" || {
  echo "reusable workflow does not invoke the CPE network bootstrap helper"
  exit 1
}

unknown_inputs=''
for input in $(sed -n '/^[[:space:]]*with:/,$s/^      \([A-Z][A-Z0-9_]*\):.*/\1/p' "$WORKFLOW"); do
  if ! grep -q "^      $input:\$" "$CORE"; then
    unknown_inputs="$unknown_inputs $input"
  fi
done
[ -z "$unknown_inputs" ] || {
  echo "CPE-5G workflow passes unknown WRT-CORE inputs:$unknown_inputs"
  exit 1
}

grep -q 'CI_NAME: CPE-5G-6.18-MANUAL' "$WORKFLOW" || {
  echo "CPE-5G workflow must be pinned to the QCA-6.18 build track"
  exit 1
}

[ -f "$DOC" ] || {
  echo "missing CPE-5G preset documentation"
  exit 1
}

echo "CPE-5G preset test passed"
