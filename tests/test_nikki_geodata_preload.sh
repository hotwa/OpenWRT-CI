#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
HANDLES_SH="$ROOT_DIR/Scripts/Handles.sh"
URL_DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/98-nikki-geodata-url-defaults"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$HANDLES_SH" ] || { echo "missing Handles.sh"; exit 1; }

grep -q 'mkdir -p "\$GITHUB_WORKSPACE/files/etc/nikki/run"' "$HANDLES_SH" || {
  echo "Handles.sh does not create the Nikki geodata staging directory"
  exit 1
}

grep -q 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat' "$HANDLES_SH" || {
  echo "Handles.sh does not download geoip.dat from jsDelivr"
  exit 1
}

grep -q 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat' "$HANDLES_SH" || {
  echo "Handles.sh does not download geosite.dat from jsDelivr"
  exit 1
}

grep -q 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb' "$HANDLES_SH" || {
  echo "Handles.sh does not download geoip.metadb from jsDelivr"
  exit 1
}

grep -q '\$GITHUB_WORKSPACE/files/etc/nikki/run/geoip.dat' "$HANDLES_SH" || {
  echo "Handles.sh does not stage geoip.dat into files/etc/nikki/run"
  exit 1
}

grep -q '\$GITHUB_WORKSPACE/files/etc/nikki/run/geosite.dat' "$HANDLES_SH" || {
  echo "Handles.sh does not stage geosite.dat into files/etc/nikki/run"
  exit 1
}

grep -q '\$GITHUB_WORKSPACE/files/etc/nikki/run/geoip.metadb' "$HANDLES_SH" || {
  echo "Handles.sh does not stage geoip.metadb into files/etc/nikki/run"
  exit 1
}

grep -q 'mkdir -p ./wrt/files' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not create the OpenWrt files overlay directory"
  exit 1
}

grep -q 'cp -rf ./files/. ./wrt/files/' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not copy repository files overlays into ./wrt/files"
  exit 1
}

[ -x "$URL_DEFAULTS" ] || { echo "missing Nikki geodata UCI defaults"; exit 1; }
sh -n "$URL_DEFAULTS"
for option in geoip_dat_url geosite_url geoip_asn_url; do
  grep -q "nikki.mixin.$option" "$URL_DEFAULTS" || { echo "missing Nikki UCI default: $option"; exit 1; }
done
grep -q "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb" "$URL_DEFAULTS" || { echo "missing jsDelivr ASN UCI default"; exit 1; }
! grep -Fq "gitea.jmsu.top" "$HANDLES_SH" "$URL_DEFAULTS" || { echo "Nikki geodata must not use gitea.jmsu.top"; exit 1; }

echo "nikki geodata preload test passed"
