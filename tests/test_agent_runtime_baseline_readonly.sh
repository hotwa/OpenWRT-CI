#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT="$ROOT_DIR/files/etc/init.d/agent-runtime-baseline-readonly"
DEFAULTS="$ROOT_DIR/files/etc/uci-defaults/94-agent-runtime-baseline-readonly"
PROFILE="$ROOT_DIR/files/etc/profile.d/20-node-agent.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$INIT" ] && [ -x "$DEFAULTS" ] || { echo 'baseline readonly boot wiring is missing' >&2; exit 1; }
sh -n "$INIT"
sh -n "$DEFAULTS"
bash -n "$PROFILE"
grep -Fq 'export COMMANDCODE_SKIP_UPDATES=1' "$PROFILE"
grep -Fq 'mount -o remount,bind,ro' "$INIT"

BIN="$WORK/bin"
MOUNTS="$WORK/mounts"
mkdir -p "$BIN" "$WORK/opt/node" "$WORK/opt/uv" "$WORK/opt/agent-runtime"
: >"$MOUNTS"
cat >"$BIN/mount" <<'EOF'
#!/bin/sh
mounts="${TEST_MOUNTS:?}"
if [ "$1" = --bind ]; then
  printf 'none %s none rw,bind 0 0\n' "$3" >>"$mounts"
  printf 'bind %s\n' "$3" >>"${MOUNT_CALLS:?}"
elif [ "$1" = -o ]; then
  target="$3"
  awk -v target="$target" '$2 != target { print; next } { $4="ro,bind"; print }' "$mounts" >"$mounts.tmp"
  mv "$mounts.tmp" "$mounts"
  printf 'readonly %s\n' "$target" >>"${MOUNT_CALLS:?}"
else
  exit 2
fi
EOF
cat >"$BIN/umount" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$BIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$BIN"/*

# Old self-referential PID symlinks are removed only when the process is gone;
# unrelated or live temporary paths are preserved.
ln -s "$WORK/opt/node" "$WORK/opt/node/.node.new.99999999"
ln -s "$WORK/opt/agent-runtime" "$WORK/opt/agent-runtime/current.new.not-a-pid"
ln -s "$WORK/opt/agent-runtime" "$WORK/opt/agent-runtime/previous.new.99999999"
touch "$MOUNTS"
export TEST_MOUNTS="$MOUNTS" MOUNT_CALLS="$WORK/calls"
export AGENT_RUNTIME_READONLY_DIRS="$WORK/opt/node $WORK/opt/uv $WORK/opt/agent-runtime"
export AGENT_RUNTIME_MOUNTS_FILE="$MOUNTS" PATH="$BIN:$PATH"
. "$INIT"
start
[ ! -e "$WORK/opt/node/.node.new.99999999" ]
[ -L "$WORK/opt/agent-runtime/current.new.not-a-pid" ]
[ ! -e "$WORK/opt/agent-runtime/previous.new.99999999" ]
for directory in "$WORK/opt/node" "$WORK/opt/uv" "$WORK/opt/agent-runtime"; do
  awk -v target="$directory" '$2 == target && $4 ~ /ro/ { found=1 } END { exit !found }' "$MOUNTS"
done
first_count="$(wc -l <"$MOUNT_CALLS")"
start
[ "$(wc -l <"$MOUNT_CALLS")" -eq "$first_count" ]

echo 'agent runtime readonly baseline tests passed'
