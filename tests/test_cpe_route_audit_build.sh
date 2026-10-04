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
echo 'CPE route audit build checks passed'
node --test "$ROOT_DIR/tests/test_cpe_route_audit_bootstrap.mjs"
