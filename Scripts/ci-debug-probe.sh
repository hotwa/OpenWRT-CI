#!/usr/bin/env bash
# CI Debug Gate - env probe (read-only)
# Usage from agent:  ssh runner@100.64.0.x "bash <repo>/Scripts/ci-debug-probe.sh"
# No sudo required. All find calls are depth-bounded to avoid I/O storms.
set -u

echo "========================================================================"
echo "CI DEBUG ENV PROBE"
echo "Date: $(date -u "+%Y-%m-%d %H:%M:%S UTC")"
echo "Host: $(hostname) ($(uname -m))"
echo "User: $(whoami) (UID: $(id -u), GID: $(id -g))"
echo ""

echo "=== [1/7] WORKSPACE & DISK ==="
echo "GITHUB_WORKSPACE = ${GITHUB_WORKSPACE:-/home/runner/work}"
echo "Current PWD      = $(pwd)"
df -h . 2>/dev/null || true
echo ""

echo "=== [2/7] BINFMT & QEMU MISC ==="
if [ -d /proc/sys/fs/binfmt_misc ]; then
  echo "Registered binfmt_misc entries:"
  ls -1 /proc/sys/fs/binfmt_misc 2>/dev/null
  for f in /proc/sys/fs/binfmt_misc/qemu-*; do
    [ -f "$f" ] || continue
    echo "--- $f ---"
    cat "$f"
  done
else
  echo "WARN: /proc/sys/fs/binfmt_misc not mounted or unavailable!"
fi
echo ""
echo "Installed QEMU user binaries:"
for q in qemu-aarch64 qemu-aarch64-static qemu-arm qemu-arm-static qemu-mips qemu-mipsel qemu-x86_64; do
  if command -v "$q" >/dev/null 2>&1; then
    echo "  $q -> $(command -v "$q") ($("$q" --version 2>/dev/null | head -n1))"
  fi
done
echo ""

WRT_DIR="${GITHUB_WORKSPACE:-/home/runner/work}/wrt"
echo "=== [3/7] OPENWRT STAGING & TOOLCHAIN DIRS ==="
if [ -d "$WRT_DIR" ]; then
  find "$WRT_DIR" -maxdepth 3 -type d \( -name staging_dir -o -name build_dir \) 2>/dev/null
  echo ""
  echo "Toolchains & host targets in staging_dir:"
  find "$WRT_DIR/staging_dir" -maxdepth 2 -type d 2>/dev/null | head -n 30
else
  echo "WARN: $WRT_DIR does not exist!"
fi
echo ""

echo "=== [4/7] BROKEN SYMLINKS AUDIT ==="
if [ -d "$WRT_DIR/staging_dir" ]; then
  broken_links=$(find "$WRT_DIR/staging_dir" -xtype l 2>/dev/null)
  if [ -n "$broken_links" ]; then
    echo "Detected broken symlinks in staging_dir:"
    echo "$broken_links" | head -n 30
  else
    echo "No broken symlinks in staging_dir."
  fi
else
  echo "SKIP: no staging_dir"
fi
echo ""

echo "=== [5/7] MUSL LOADERS & TARGET LIBS ==="
find "$WRT_DIR/staging_dir" -name "ld-musl-*.so.1" -o -name libc.so 2>/dev/null | head -n 30
echo ""

echo "=== [6/7] AGENT RUNTIME STACK (NODE / PYTHON / UV) ==="
for c in node npm pnpm python python3 uv; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  $c -> $(command -v "$c") ($("$c" --version 2>/dev/null | head -n1))"
  fi
done
if command -v node >/dev/null 2>&1; then
  node -e "console.log({arch: process.arch, platform: process.platform, node: process.versions.node})" 2>/dev/null
fi
echo ""

echo "=== [7/7] CROSS-COMPILE RELEVANT ENV VARS ==="
env | sort | grep -E "^(PATH|STAGING_DIR|TOOLCHAIN_DIR|ARCH|TARGET|CROSS_COMPILE|CC|CXX|LD|AR|NODE_|UV_|PYTHON)" || echo "(none)"
echo ""
echo "========================================================================"
echo "Probe completed."
echo "========================================================================"