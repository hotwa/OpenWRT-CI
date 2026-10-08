#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/files/etc/nikki" "$D/files/etc/init.d" "$D/files/etc/crontabs"
printf 'CONFIG_PACKAGE_luci-app-nikki=y\nCONFIG_PACKAGE_nikki=y\nCONFIG_PACKAGE_luci-app-momo=y\n' > "$D/.config"
touch "$D/files/etc/init.d/nikki-subscription-sync"
printf '* * * * * /usr/sbin/nikki-subscription-sync\n0 0 * * * /usr/sbin/agent-runtime-health-check\n' > "$D/files/etc/crontabs/root"
bash "$ROOT/Scripts/ConfigureWlgOpenClash.sh" configure "$D" openclash
bash "$ROOT/Scripts/ConfigureWlgOpenClash.sh" verify "$D" openclash
[ ! -e "$D/files/etc/nikki" ]; [ ! -e "$D/files/etc/init.d/nikki-subscription-sync" ]
grep -q agent-runtime-health-check "$D/files/etc/crontabs/root"
sed -i '/CONFIG_PACKAGE_luci-app-openclash=y/d' "$D/.config"
if bash "$ROOT/Scripts/ConfigureWlgOpenClash.sh" verify "$D" openclash 2>/dev/null; then exit 1; fi
if bash "$ROOT/Scripts/ConfigureWlgOpenClash.sh" configure "$D" unknown 2>/dev/null; then exit 1; fi
cp "$D/.config" "$D/before"
bash "$ROOT/Scripts/ConfigureWlgOpenClash.sh" configure "$D" nikki
cmp "$D/.config" "$D/before"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys,yaml
r=Path(sys.argv[1]); pin='0fb9b10cb9df51fb076470e1dd93d1c30dd89d83'
for model in ['RE-CS-07','RE-SS-01']:
 j=yaml.safe_load((r/f'.github/workflows/WLG-{model}-BUILD.yml').read_text());w=j['jobs']['build']['with'];assert w['WRT_COMMIT']==pin and w['WRT_PROXY_PROFILE']=='openclash';assert w['WRT_EMMC_DATA_PROVISIONING'] is True;assert w['WRT_CONTAINER_RUNTIME_TEST'] is True
j=yaml.safe_load((r/'.github/workflows/WLG-RE-SS-01-BUILD.yml').read_text());assert j['jobs']['build']['with']['WRT_REQUIRED_DEVICE']=='jdcloud_re-ss-01';assert j['jobs']['build']['with']['WRT_CONFIG']=='IPQ60XX-RE-SS-01'
import json
assert json.loads((r/'files/etc/pi/agent/modes.config.json').read_text())['defaultMode']=='yolo'
assert 'vernesong/OpenClash" "master"' in (r/'Scripts/Packages.sh').read_text()
PY
echo 'WLG proxy isolation and two model gates passed'
