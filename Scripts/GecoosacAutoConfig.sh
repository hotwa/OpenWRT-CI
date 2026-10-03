#!/bin/bash
set -euo pipefail
TARGET_FILES="${1:?firmware files directory is required}"
[ -n "${GECOOSAC_WIFI_PASSWORD:-}" ] || exit 0
# Secret travels via the environment, never a shell argument or stdout.
python3 - "$TARGET_FILES" <<'PY'
import json, os, pathlib
p = pathlib.Path(__import__('sys').argv[1]) / 'etc/gecoosac-auto/profile.json'
if not p.exists():
    raise SystemExit('gecoosac-auto profile is missing')
key = os.environ['GECOOSAC_WIFI_PASSWORD']
if not 8 <= len(key) <= 63 or any(not 32 <= ord(c) <= 126 for c in key):
    raise SystemExit('gecoosac-auto requires an ASCII WPA2 password of 8-63 characters')
profile = json.loads(p.read_text())
profile['fallback_key'] = key
p.write_text(json.dumps(profile, indent=2) + '\n')
p.chmod(0o600)
PY
