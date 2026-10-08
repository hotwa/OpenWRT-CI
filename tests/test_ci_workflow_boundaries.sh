#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# WLG retains its existing build/release wiring; production fleet CD was not
# among the selected absorptions. Validate the explicit WLG secret boundary.
python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re, sys
root=Path(sys.argv[1])
core=(root/'.github/workflows/WRT-CORE.yml').read_text()
declared=set(re.findall(r'^      ([A-Z][A-Z0-9_]*):$',core.split('    secrets:',1)[1].split('\nenv:',1)[0],re.M))
for name in ('WLG-RE-CS-07-BUILD.yml','WLG-RE-SS-01-BUILD.yml'):
    text=(root/'.github/workflows'/name).read_text()
    assert 'secrets: inherit' not in text, name
    mapped=set(re.findall(r'^      ([A-Z][A-Z0-9_]*): \$\{\{ secrets\.',text,re.M))
    assert mapped and mapped <= declared, (name,mapped-declared)
    assert 'OPENWRT_DROPBEAR_AUTHORIZED_KEYS' in mapped
    assert 'COMMANDCODE_API_KEY' not in mapped, 'WLG must not inject provider credentials'
    assert not any(v.startswith(('CPE_','FIRMWARE_CD_')) for v in mapped)
    assert 'WRT_BUILD_ONLY: true' in text
assert 'FIRMWARE_CD_SSH_PRIVATE_KEY' not in core
assert not (root/'.github/workflows/FIRMWARE-FLEET-CD.yml').exists()
print('WLG explicit secret allowlists and build-only boundary passed')
PY
