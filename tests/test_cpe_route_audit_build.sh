#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
cc -Wall -Wextra -Werror -O2 -o "$task_tmp/audit" "$ROOT_DIR/Scripts/cpe5g-ipv6/route-audit-package/src/route-audit.c"
# A read-only dump must complete without changing a route or requiring NET_ADMIN.
timeout 5 "$task_tmp/audit" >"$task_tmp/routes"
! grep -Ev '^.* dev usb0 table (181|200) proto 196 metric 665$' "$task_tmp/routes"
grep -Fq -- '-static' "$ROOT_DIR/Scripts/cpe5g-ipv6/route-audit-package/Makefile"
grep -Fq 'CONFIG_PACKAGE_cpe6-route-audit=y' "$ROOT_DIR/.github/workflows/WRT-CORE.yml"
python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import os, shutil, subprocess, sys, tempfile, textwrap

root=Path(sys.argv[1])
core=(root/'.github/workflows/WRT-CORE.yml').read_text()
start='            if [ "${WRT_CPE_IPV6:-false}" = "true" ]; then\n'
# Exercise the actual package-staging block, not a copy of its guard.
block=textwrap.dedent(start+core.split(start,1)[1].split('\n            fi',1)[0]+'\n            fi\n')
source=root/'Scripts/cpe5g-ipv6/route-audit-package'
cases=0
with tempfile.TemporaryDirectory(prefix='cpe-route-audit-staging-') as name:
 workspace=Path(name)
 shutil.copytree(source,workspace/'Scripts/cpe5g-ipv6/route-audit-package')
 base={**os.environ,'GITHUB_WORKSPACE':name,'WRT_CPE_IPV6':'true',
       'WRT_REQUIRED_DEVICE':'jdcloud_re-ss-01','WRT_EXPECTED_DEVICE':''}
 def check(env,ok,staged):
  global cases
  shutil.rmtree(workspace/'wrt',ignore_errors=True)
  result=subprocess.run(['bash','-e','-c',block],cwd=workspace,env=env,capture_output=True,text=True)
  assert (result.returncode==0)==ok, 'unexpected route-audit staging result: '+result.stderr
  target=workspace/'wrt/package/cpe6-route-audit'
  assert target.exists()==staged
  if staged:
   for path in source.rglob('*'):
    if path.is_file():assert (target/path.relative_to(source)).read_bytes()==path.read_bytes()
  if not ok:assert 'ERROR: CPE IPv6 route audit requires WRT_REQUIRED_DEVICE=jdcloud_re-ss-01' in result.stderr
  cases+=1
 # The CPE caller supplies REQUIRED; EXPECTED intentionally remains empty.
 check(base,True,True)
 check({**base,'WRT_EXPECTED_DEVICE':'jdcloud_re-cs-02'},True,True)
 missing={**base,'WRT_EXPECTED_DEVICE':'jdcloud_re-ss-01'}
 missing.pop('WRT_REQUIRED_DEVICE')
 check(missing,False,False)
 check({**base,'WRT_REQUIRED_DEVICE':'','WRT_EXPECTED_DEVICE':'jdcloud_re-ss-01'},False,False)
 check({**base,'WRT_REQUIRED_DEVICE':'jdcloud_re-cs-02','WRT_EXPECTED_DEVICE':'jdcloud_re-ss-01'},False,False)
 check({**missing,'WRT_CPE_IPV6':'false'},True,False)
print('CPE route audit workflow staging: %d fixtures passed'%cases)
PY
echo 'CPE route audit build checks passed'
node --test "$ROOT_DIR/tests/test_cpe_route_audit_bootstrap.mjs"
node --test "$ROOT_DIR/tests/test_cpe_quota_logger.mjs"
node --test "$ROOT_DIR/tests/test_cpe_local_failover.mjs"
