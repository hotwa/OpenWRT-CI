#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
cat > "$WORK/bin/cat" <<'EOF'
#!/bin/sh
[ "$1" != /tmp/sysinfo/board_name ] || { echo jdcloud,re-ss-01; exit; }
exec /bin/cat "$@"
EOF
cat > "$WORK/bin/awk" <<'EOF'
#!/usr/bin/env python3
import os,sys
args=[os.environ['TEST_MEMINFO'] if x=='/proc/meminfo' else os.environ['TEST_MOUNTS'] if x=='/proc/mounts' else x for x in sys.argv[1:]]
os.execv('/usr/bin/awk',['awk',*args])
EOF
cat > "$WORK/bin/mount" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\ntmpfs 999999 0 %s 0%% /tmp\n' "$TEST_TMP_FREE"
EOF
cat > "$WORK/bin/du" <<'EOF'
#!/bin/sh
printf '100\t/etc\n'
EOF
chmod +x "$WORK/bin/"*
printf 'tmpfs /tmp tmpfs rw 0 0\n' > "$WORK/mounts"
truncate -s 8388608 "$WORK/image.bin"
export TEST_MEMINFO="$WORK/meminfo" TEST_MOUNTS="$WORK/mounts" TEST_TMP_FREE=300000
export PATH="$WORK/bin:$PATH"
cd "$WORK"
mem() { printf 'MemAvailable: %s kB\nSwapFree: 10000000 kB\n' "$1" > "$TEST_MEMINFO"; }
mem 200000
sh "$ROOT/files/usr/sbin/openwrt-upgrade-space" check image.bin >/dev/null
mem 100000
if sh "$ROOT/files/usr/sbin/openwrt-upgrade-space" check image.bin > "$WORK/result" 2>&1; then
  echo 'large zram must not permit a low-RAM image copy' >&2; exit 1
fi
grep -q 'MemAvailable=' "$WORK/result"
# Reusing an already allocated /tmp image must not reserve another copy.
sh "$ROOT/files/usr/sbin/openwrt-upgrade-space" check "$WORK/image.bin" >/dev/null
mem 98000
if sh "$ROOT/files/usr/sbin/openwrt-upgrade-space" check "$WORK/image.bin" >/dev/null 2>&1; then
  echo 'staged image must still retain configuration and machinery reserve' >&2; exit 1
fi
mem 200000
export TEST_TMP_FREE=100000
if sh "$ROOT/files/usr/sbin/openwrt-upgrade-space" check image.bin >/dev/null 2>&1; then
  echo 'ample RAM must not bypass tmpfs free-space failure' >&2; exit 1
fi
sh "$ROOT/files/usr/sbin/openwrt-upgrade-space" check "$WORK/image.bin" >/dev/null
printf 'Malformed: 200000 kB\n' > "$TEST_MEMINFO"
if sh "$ROOT/files/usr/sbin/openwrt-upgrade-space" check "$WORK/image.bin" >/dev/null 2>&1; then
  echo 'missing MemAvailable must fail closed' >&2; exit 1
fi
echo 'upgrade memory gate behavioral tests passed'
