#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
WORKFLOW="$ROOT_DIR/.github/workflows/CPE-5G.yml"
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

grep -q 'WRT_LAN_TAILNET: false' "$WORKFLOW" || {
  echo "CPE-5G workflow must keep LAN-to-tailnet forwarding disabled by default"
  exit 1
}

[ -f "$DOC" ] || {
  echo "missing CPE-5G preset documentation"
  exit 1
}

echo "CPE-5G preset test passed"
