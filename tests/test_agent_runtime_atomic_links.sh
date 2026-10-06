#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$ROOT_DIR/files/usr/sbin/agent-runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export AGENT_RUNTIME_DATA_ROOT="$WORK/data"
export AGENT_RUNTIME_BASELINE="$WORK/opt/agent-runtime"
mkdir -p "$WORK/opt/node/bin" "$WORK/opt/uv" "$AGENT_RUNTIME_BASELINE" "$AGENT_RUNTIME_DATA_ROOT/agent-runtime"
ln -s ../node "$AGENT_RUNTIME_BASELINE/node"
ln -s ../uv "$AGENT_RUNTIME_BASELINE/uv"
printf '#!/bin/sh\nexit 0\n' > "$WORK/opt/uv/uv"
chmod 0755 "$WORK/opt/uv/uv"
ln -s "$WORK/opt/node" "$AGENT_RUNTIME_DATA_ROOT/node"
ln -s "$AGENT_RUNTIME_BASELINE" "$AGENT_RUNTIME_DATA_ROOT/agent-runtime/current"
ln -s "$AGENT_RUNTIME_BASELINE" "$AGENT_RUNTIME_DATA_ROOT/agent-runtime/previous"

# Load the real functions without entering CLI dispatch, locking, or probes.
eval "$(awk '/^case "\$#" in$/{exit}{print}' "$MANAGER")"

assert_no_target_writes() {
  if find "$WORK/opt" -name '*.new.*' -print -quit | grep -q .; then
    echo 'atomic link replacement wrote a temporary symlink into the firmware target' >&2
    exit 1
  fi
}

# Existing links to directories must be replaced themselves. Without -T,
# mv succeeds in this writable fixture but silently writes below /opt instead.
for iteration in 1 2; do
  set_current "$BASELINE"
  [ "$(readlink "$DATA_ROOT/node")" = "$WORK/opt/node" ]
  [ "$(readlink "$ROOT/current")" = "$BASELINE" ]
  [ "$(readlink "$ROOT/previous")" = "$BASELINE" ]
  assert_no_target_writes
done

# Exercise each helper independently so a fix to one cannot mask the other.
publish_node_link "$BASELINE"
link_atomically "$ROOT/current" "$BASELINE"
assert_no_target_writes

# Safety guards remain in force: a retained real directory is never replaced.
mkdir "$ROOT/operator-directory"
printf 'preserve\n' > "$ROOT/operator-directory/sentinel"
if link_atomically "$ROOT/operator-directory" "$BASELINE"; then
  echo 'atomic helper replaced an administrator-owned directory' >&2
  exit 1
fi
[ "$(cat "$ROOT/operator-directory/sentinel")" = preserve ]

echo 'agent runtime atomic directory-symlink replacement and repeated activation passed'
