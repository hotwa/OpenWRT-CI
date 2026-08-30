#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PKG="$ROOT_DIR/package/luci-app-agent-runtime"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
RPCD="$PKG/root/usr/share/rpcd/ucode/agent-runtime.uc"
HELPER="$PKG/root/usr/libexec/agent-runtime-rpcd-job"
ACL="$PKG/root/usr/share/rpcd/acl.d/luci-app-agent-runtime.json"
VIEW="$PKG/htdocs/luci-static/resources/view/agent-runtime/overview.js"
MENU="$PKG/root/usr/share/luci/menu.d/luci-app-agent-runtime.json"

for file in "$PKG/Makefile" "$RPCD" "$HELPER" "$ACL" "$VIEW" "$MENU"; do
	[ -f "$file" ] || { echo "missing $file" >&2; exit 1; }
done

grep -q '^CONFIG_PACKAGE_luci-app-agent-runtime=y$' "$GENERAL"

grep -q 'admin/system/agent-runtime' "$MENU"
grep -q 'Agent Runtime' "$VIEW"
grep -q 'Baked baseline' "$VIEW"
grep -q 'Latest signed release' "$VIEW"
grep -q 'Components and runtime contract' "$VIEW"
# The ubus API must remain a fixed allow-list, with no generic execute endpoint.
for action in status list check upgrade rollback verify gc job_status operation_log; do
	grep -q "$action" "$RPCD" || { echo "missing fixed action $action" >&2; exit 1; }
done
! grep -Eq 'args:.*(command|url|path|package)' "$RPCD"
grep -q "fs.popen(\[ RUNTIME, action, '--json' \]" "$RPCD"
grep -q "fs.popen(\[ JOB_HELPER, action \]" "$RPCD"
grep -q 'valid_id' "$RPCD"
grep -q 'request.args.job_id' "$RPCD"
grep -q 'request.args.operation_id' "$RPCD"
grep -q "'/usr/bin/tail'" "$RPCD"
grep -q 'MAX_OUTPUT = 16384' "$RPCD"
grep -q 'chmod 0755' "$PKG/Makefile"

# ACL grants only this object and only the declared methods.
grep -q '"agent-runtime"' "$ACL"
! grep -q '"file"' "$ACL"
! grep -q '"exec"' "$ACL"

# The detached helper has a second, independent allow-list and never evals input.
grep -q 'check|upgrade|rollback|verify|gc' "$HELPER"
! grep -q '\beval\b' "$HELPER"
grep -q 'tail -c 16384' "$HELPER"

echo "luci Agent Runtime package guard passed"
