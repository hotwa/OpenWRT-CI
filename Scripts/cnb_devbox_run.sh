#!/usr/bin/env bash
# CNB devbox adapter for the long private RE-CS-07 compile.
#
# The observed build-pipeline limit is 120 minutes, so this adapter runs the
# reviewed replay inside a 云原生开发 environment (service.vscode) instead:
#   * the replay keeps every allocated CPU (CNB_REPLAY_CPU_PIN=native) because
#     firmware bytes do not depend on the job count, only the wall clock does;
#   * the build is detached with setsid, so a stage timeout cannot kill it;
#   * this stage only streams the log and, when the build ends, reports the
#     artifact set, SHA256SUMS, metadata and guard result into the stage log.
# No release, deployment or device access. Secret values are never printed.
set -euo pipefail
set +x
unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN

workspace="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$workspace"

[ -f .github/workflows/WRT-CORE.yml ] || {
  echo 'ERROR: expected private build checkout is absent' >&2; exit 1;
}
[ ! -e wrt ] || {
  echo 'ERROR: wrt/ already exists; the replay requires a fresh checkout' >&2; exit 1;
}
[ -n "${SAMBA_DEFAULT_PASSWORD:-}" ] || {
  echo 'ERROR: SAMBA_DEFAULT_PASSWORD is required for the default RE firmware profile' >&2;
  exit 1;
}
command -v runuser >/dev/null || { echo 'ERROR: runuser unavailable' >&2; exit 1; }
id cnbbuild >/dev/null 2>&1 || { echo 'ERROR: cnbbuild user is absent' >&2; exit 1; }

log="$workspace/cnb-devbox-build.log"
pid_file="$workspace/cnb-devbox-build.pid"
heartbeat="$workspace/cnb-devbox-heartbeat"
[ ! -e "$log" ] || {
  echo "ERROR: previous devbox build log exists ($log); remove it before a new run" >&2;
  exit 1;
}

echo '==== devbox environment ===='
uname -a
printf 'nproc=%s affinity=%s\n' "$(nproc)" \
  "$(python3 -c 'import os; print(len(os.sched_getaffinity(0)))')"
for limit in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  [ -r "$limit" ] && printf 'cgroup %s=%s\n' "$limit" "$(cat "$limit")"
done
df -h "$workspace" /tmp 2>/dev/null | sed -n '1,4p' || true
echo '============================'

# Detach: the platform stage/job timeout must never terminate this compile.
setsid nohup runuser --preserve-environment -u cnbbuild -- \
  env HOME=/home/cnbbuild CNB_REPLAY_CPU_PIN=native \
  python3 -u Scripts/cnb_replay_core.py re-cs-07 >"$log" 2>&1 </dev/null &
child=$!
printf '%s\n' "$child" > "$pid_file"
printf 'detached replay pid=%s log=%s\n' "$child" "$log"

waited=0
rc=0
while kill -0 "$child" 2>/dev/null; do
  sleep 60
  waited=$((waited + 60))
  printf '#### heartbeat %ss: %s\n' "$waited" \
    "$(grep -c 'CNB replay GHA build stage' "$log" 2>/dev/null || echo 0) replay stages started"
  printf '%s %ss %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$waited" \
    "$(tail -n 1 "$log" 2>/dev/null | cut -c1-180)" > "$heartbeat"
  tail -n 15 "$log" 2>/dev/null || true
done
wait "$child" || rc=$?

echo "==== replay finished rc=$rc after ${waited}s ===="
tail -n 60 "$log" 2>/dev/null || true

upload="$workspace/wrt/upload"
if [ -d "$upload" ]; then
  echo '==== devbox artifact report ===='
  du -sh "$upload" 2>/dev/null || true
  find "$upload" -maxdepth 1 -type f -printf '%10s  %f\n' 2>/dev/null | sort -k2 || true
  if [ -f "$upload/SHA256SUMS" ]; then
    echo '---- SHA256SUMS ----'
    cat "$upload/SHA256SUMS"
  fi
  if [ -f "$upload/metadata.json" ]; then
    echo '---- metadata.json ----'
    cat "$upload/metadata.json"
  fi
  [ -f "$workspace/wrt/.config" ] && printf '.config sha256 %s\n' \
    "$(sha256sum "$workspace/wrt/.config" | cut -d' ' -f1)"
  manifest="$(find "$workspace/wrt/bin/targets" -type f -name '*.manifest' 2>/dev/null | head -n 1 || true)"
  if [ -n "$manifest" ]; then
    printf 'manifest %s: luci packages=%s\n' "${manifest##*/}" \
      "$(grep -c '^luci-' "$manifest" || true)"
    grep -E '^kernel - ' "$manifest" || true
  fi
  printf 'rc=%s waited=%ss upload=%s\n' "$rc" "$waited" "$upload" \
    > "$workspace/cnb-devbox-result.txt"
  echo "resume file: $workspace/cnb-devbox-result.txt"
else
  echo '==== no wrt/upload directory was produced ===='
  printf 'rc=%s waited=%ss upload=absent\n' "$rc" "$waited" \
    > "$workspace/cnb-devbox-result.txt"
fi

[ "$rc" -eq 0 ] || exit "$rc"
echo 'CNB devbox RE-CS-07 replay finished; inspect the report above'
