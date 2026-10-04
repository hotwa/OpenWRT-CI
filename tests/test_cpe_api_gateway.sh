#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
node "$ROOT/tests/test_cpe_api_gateway.mjs"
for file in "$ROOT/Scripts/ConfigureCpeApiGateway.sh" "$ROOT/Scripts/cpe5g-api/init" "$ROOT/Scripts/cpe5g-api/launcher"; do sh -n "$file"; done
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir -p "$TASK_TMP/false"
sh "$ROOT/Scripts/ConfigureCpeApiGateway.sh" "$TASK_TMP/false" false
[ ! -e "$TASK_TMP/false/etc/init.d/cpe-api" ]
mkdir -p "$TASK_TMP/true/etc/init.d" "$TASK_TMP/true/usr/libexec"
if sh "$ROOT/Scripts/ConfigureCpeApiGateway.sh" "$TASK_TMP/true" true 2>/dev/null; then echo 'missing CPE/runtime gate accepted' >&2; exit 1; fi
touch "$TASK_TMP/true/etc/init.d/containerd-test" "$TASK_TMP/true/usr/libexec/cpe5g-mwan3-gated-reconcile"
chmod +x "$TASK_TMP/true/usr/libexec/cpe5g-mwan3-gated-reconcile"
sh "$ROOT/Scripts/ConfigureCpeApiGateway.sh" "$TASK_TMP/true" true
[ -x "$TASK_TMP/true/usr/sbin/cpe-api" ]
[ -f "$TASK_TMP/true/lib/upgrade/keep.d/cpe-api" ]
[ -x "$TASK_TMP/true/etc/uci-defaults/98-cpe-api" ]
rg -q '^/etc/init.d/cpe-api start$' "$TASK_TMP/true/etc/uci-defaults/98-cpe-api"
python3 - "$TASK_TMP/true/etc/uci-defaults/98-cpe-api" "$ROOT/files-container-runtime-test/etc/uci-defaults/97-containerd-test-enable" <<'PY_HOOK'
import pathlib,sys
app,runtime=map(pathlib.Path,sys.argv[1:])
assert runtime.is_file() and app.name>runtime.name
commands=[line.strip() for line in app.read_text().splitlines() if line.startswith('/etc/init.d/')]
assert commands==['/etc/init.d/cpe-api enable','/etc/init.d/cpe-api start']
PY_HOOK

! rg -q 'pull|network reload|netifd' "$TASK_TMP/true/etc/init.d/cpe-api"
# Shutdown/ordinary init stop must never persist the operator disable marker.
! sed -n '/^stop_service()/,/^}/p' "$TASK_TMP/true/etc/init.d/cpe-api" | rg -q '/usr/sbin/cpe-api stop|uci set|disabled'
python3 - "$ROOT/.github/workflows/CPE-5G.yml" <<'PY'
import sys
s=open(sys.argv[1]).read(); a,b=s.split('  cpe_overlay_b:',1)
assert 'WRT_CONTAINER_RUNTIME_TEST: true' not in a
assert 'WRT_CPE_API_GATEWAY: true' not in a
for expected in ['WRT_CONTAINER_RUNTIME_TEST: true','WRT_CONTAINER_RUNTIME_MODE: prebuilt',"WRT_CONTAINER_RUNTIME_VERSION: '2.4.1'",'WRT_CPE_API_GATEWAY: true']: assert expected in b
PY
printf '%s\n' 'CPE API overlay and B-only runtime gate passed'
