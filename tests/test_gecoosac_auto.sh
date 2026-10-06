#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --check "$ROOT/files/usr/libexec/gecoosac-auto.js"
node "$ROOT/tests/test_gecoosac_auto.js"
for file in files/usr/sbin/gecoosac-auto files/etc/init.d/gecoosac-auto files/etc/uci-defaults/99-gecoosac-auto; do
  sh -n "$ROOT/$file"
done
bash -n "$ROOT/Scripts/GecoosacAutoConfig.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/etc/gecoosac-auto"
cp "$ROOT/files/etc/gecoosac-auto/profile.json" "$WORK/etc/gecoosac-auto/profile.json"
bash "$ROOT/Scripts/PrivateFirmwareGuard.sh" "$WORK" > "$WORK/public.env"
grep -qx 'WRT_PRIVATE_BUILD=false' "$WORK/public.env"
GECOOSAC_WIFI_PASSWORD='fixture-only-pass' bash "$ROOT/Scripts/GecoosacAutoConfig.sh" "$WORK"
bash "$ROOT/Scripts/PrivateFirmwareGuard.sh" "$WORK" > "$WORK/private.env"
grep -qx 'WRT_PRIVATE_BUILD=true' "$WORK/private.env"
grep -q 'gecoosac-wifi-password' "$WORK/private.env"
if grep -q 'fixture-only-pass' "$WORK/private.env"; then
  echo 'AP password leaked into guard output'; exit 1
fi
printf '%s\n' '{invalid-credential-json' > "$WORK/etc/gecoosac-auto/profile.json"
bash "$ROOT/Scripts/PrivateFirmwareGuard.sh" "$WORK" > "$WORK/invalid.env"
grep -qx 'WRT_PRIVATE_BUILD=true' "$WORK/invalid.env"
python3 - "$ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
assert json.loads((root / 'files/etc/gecoosac-auto/profile.json').read_text())['fallback_key'] == ''
core = (root / '.github/workflows/WRT-CORE.yml').read_text()
for name in ['GecoosacAutoConfig.sh', 'gecoosac-auto.js', '99-gecoosac-auto', 'GECOOSAC_WIFI_PASSWORD']:
    assert name in core
for name, jobs in {'RE-CS-07-BUILD.yml': 1, 'RE-Mesh-BUILD.yml': 2,
                   'RE-CONTAINER-RUNTIME-TEST.yml': 3, 'QCA-6.18-VIKINGYFY.yml': 1,
                   'WLG-RE-CS-07-BUILD.yml': 1, 'CPE-5G.yml': 1}.items():
    content = (root / '.github/workflows' / name).read_text()
    assert content.count('GECOOSAC_WIFI_PASSWORD:') == jobs, name
    if name == 'CPE-5G.yml':
        assert 'GECOOSAC_WIFI_PASSWORD:' not in content.split('  cpe_overlay_b:')[0]
PY
echo 'gecoosac-auto firmware guards passed'
