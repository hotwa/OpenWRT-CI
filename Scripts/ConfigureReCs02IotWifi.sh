#!/bin/bash
set -euo pipefail
TARGET_FILES="${1:?firmware files directory is required}"
[ "${WRT_CONFIG:-}" = IPQ60XX-RE-CS-02 ] || exit 0
[ "${WRT_ENCRYPT_ARTIFACT:-false}" = true ] || { echo 'RE-CS-02 Wi-Fi credentials require encrypted artifacts' >&2; exit 1; }
python3 - "$TARGET_FILES" <<'PYTHON'
import os, pathlib, sys
key = os.environ.get('RE_CS02_IOT_WIFI_PASSWORD', '')
if not 8 <= len(key) <= 63 or any(not 32 <= ord(c) <= 126 for c in key):
    raise SystemExit('RE-CS-02 requires RE_CS02_IOT_WIFI_PASSWORD (8-63 printable ASCII characters)')
p = pathlib.Path(sys.argv[1]) / 'etc/re-cs-02/iot-wifi.key'
p.parent.mkdir(parents=True, exist_ok=True)
p.parent.chmod(0o700)
p.touch(mode=0o600)
p.chmod(0o600)
p.write_text(key)
PYTHON
