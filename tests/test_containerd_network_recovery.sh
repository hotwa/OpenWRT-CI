#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/files-container-runtime-test/etc/hotplug.d/iface/96-containerd-test
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/service" <<'SH'
#!/bin/sh
case "$1" in
enabled) exit "${DISABLED:-0}";;
running) exit "${INACTIVE:-1}";;
start) echo checked-start >> "$CALLS"; exit "${START_RESULT:-0}";;
*) exit 99;;
esac
SH
chmod +x "$tmp/service"
export CONTAINERD_TEST_SERVICE=$tmp/service CALLS=$tmp/calls
for action in ifdown remove ''; do ACTION=$action INTERFACE=wan sh "$hook"; done
ACTION=ifup INTERFACE=loopback sh "$hook"
ACTION=ifup INTERFACE=wan DISABLED=1 sh "$hook"
ACTION=ifup INTERFACE=wan INACTIVE=0 sh "$hook"
test ! -e "$CALLS"
ACTION=ifup INTERFACE=wan sh "$hook"
ACTION=ifupdate INTERFACE=wan sh "$hook"
test "$(wc -l < "$CALLS")" -eq 2
if ACTION=ifup INTERFACE=wan START_RESULT=1 sh "$hook"; then
  echo 'failed readiness must not be hidden'; exit 1
fi
! grep -Eq 'compose|restart' <(grep -v '^#' "$hook")
echo 'PASS: gated network recovery retries inactive init without bypass or live restart'
