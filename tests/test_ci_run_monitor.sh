#!/bin/bash
# =============================================================================
# test_ci_run_monitor.sh — focused tests for Scripts/ci_run_monitor.sh
#
# The monitor is exercised with a mocked `gh` (bash function exported to the
# child process) that serves fixture JSON built from the REAL structure of run
# 34315937551 (job 102352052803: steps #6 IE, #13 Smoke Tests, #25 Download
# Packages, #27 Compile Firmware).
#
# Coverage (monitoring contract):
#   1. Compile Firmware active 120 min, log still updating  -> building, never
#      cancelled.
#   2. Compile Firmware active 180 min, job in_progress     -> building (no
#      duration-based cancel; cold builds tolerated >=180 min).
#   3. Initialization Environment beyond workflow timeout   -> failure (explicit
#      failure/timeout only).
#   4. runner lost while compiling                         -> failure.
#   5. completed/success                                    -> success.
#   6. completed/cancelled                                  -> cancelled, flash=no.
#   7. two runs, not all success                           -> flash=no.
#   8. Historical replay: 34315933534 + 34315937551 at the ~75-min cancellation
#      moment (in_progress, Compile Firmware active, make in log) -> building,
#      no cancel, no flash; and their terminal state (cancelled) -> cancelled,
#      flash=no.
#   9. no-change silence: identical verdicts on consecutive ticks -> no-change.
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$ROOT_DIR/Scripts/ci_run_monitor.sh"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

[ -f "$MONITOR" ] || { echo "missing $MONITOR"; exit 1; }

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# mock gh
# ---------------------------------------------------------------------------
gh() {
  case "$1" in
    run) # gh run view <id> --repo <repo> --json ...
      local id="$3"
      local var="FAKE_RUN_${id}"
      printf '%s' "${!var:-}"
      ;;
    api) # gh api repos/<repo>/actions/runs/<id>/jobs  |  repos/<repo>/actions/jobs/<id>/logs
      local path="$2"
      if [[ "$path" == *"/actions/runs/"*"/jobs" ]]; then
        local id
        id=$(printf '%s' "$path" | sed -E 's|.*/runs/([0-9]+)/jobs|\1|')
        local var="FAKE_JOBS_${id}"
        printf '%s' "${!var:-}"
      elif [[ "$path" == *"/actions/jobs/"*"/logs" ]]; then
        local jid
        jid=$(printf '%s' "$path" | sed -E 's|.*/jobs/([0-9]+)/logs|\1|')
        local var="FAKE_LOG_${jid}"
        printf '%s' "${!var:-}"
      fi
      ;;
  esac
}
export -f gh

# run_monitor <now_iso> <run_ids...> ; echoes the verdicts/flash/event lines
run_monitor() {
  local now="$1"; shift
  CI_MONITOR_NOW="$now" bash "$MONITOR" --state-dir "$STATE_DIR" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# fixtures (structure mirrors real run 34315937551 / job 102352052803)
# ---------------------------------------------------------------------------
STEP_OK()  { printf '{"name":"%s","status":"completed","conclusion":"success","number":%s},' "$1" "$2"; }
STEP_RUN() { printf '{"name":"%s","status":"in_progress","conclusion":null,"number":%s},' "$1" "$2"; }
STEP_FAIL(){ printf '{"name":"%s","status":"completed","conclusion":"failure","number":%s},' "$1" "$2"; }

jobs_json() { # <job_status> <steps...>
  local job_status="$1"; shift
  local steps=""
  for s in "$@"; do steps="${steps}${s}"; done
  steps="${steps%,}"
  printf '{"total_count":1,"jobs":[{"id":102352052803,"name":"build / VIKINGYFY/immortalwrt","status":"%s","conclusion":null,"steps":[%s]}]}' "$job_status" "$steps"
}

RUN=$(printf '{"status":"%s","conclusion":%s,"createdAt":"%s","updatedAt":"%s","displayTitle":"RE-CS-07 Build","jobs":%s}')
# run_json <status> <conclusion|null> <createdAt> <updatedAt> <jobs_json>
run_json() {
  local status="$1" conclusion="$2" created="$3" updated="$4" jobs="$5"
  if [ "$conclusion" = "null" ]; then
    printf '{"status":"%s","conclusion":null,"createdAt":"%s","updatedAt":"%s","displayTitle":"RE-CS-07 Build","jobs":%s}' "$status" "$created" "$updated" "$jobs"
  else
    printf '{"status":"%s","conclusion":"%s","createdAt":"%s","updatedAt":"%s","displayTitle":"RE-CS-07 Build","jobs":%s}' "$status" "$conclusion" "$created" "$updated" "$jobs"
  fi
}

COMPILE_LOG='Initializing build environment
make[3] -C feeds/luci/applications/luci-app-***reboot compile
make[2] -C feeds/luci compile
python3 ./scripts/gen-deps.py --arch arm_cortex-a7
perl tools/patch.pl
go build -o staging_dir/host/bin/fdtput
ninja: no work to do
gcc -O2 -o staging_dir/host/bin/sstrip'
LOST_LOG='make[3] -C feeds/luci compile
The runner has lost communication with the server.
ERROR: Process completed with exit code 1.'

BASE_STEPS_OK="$(STEP_OK 'Set up job' 1)$(STEP_OK 'Install BC' 2)$(STEP_OK 'Free Disk Space' 3)$(STEP_OK 'Checkout Projects' 4)$(STEP_OK 'Validate LAN IP' 5)$(STEP_OK 'Initialization Environment' 6)$(STEP_OK 'Setup Go' 7)$(STEP_OK 'Check Go' 8)$(STEP_OK 'Initialization Values' 9)$(STEP_OK 'Configure Go Module Access' 10)$(STEP_OK 'Clone Code' 11)$(STEP_OK 'Check Scripts' 12)$(STEP_OK 'Repository Smoke Tests' 13)$(STEP_OK 'Compute Build Cache Identity' 14)$(STEP_OK 'Restore Build Cache' 15)$(STEP_OK 'Log Cache Restore Result' 16)$(STEP_OK 'Refresh the cache' 17)$(STEP_OK 'Update Feeds' 18)$(STEP_OK 'Record Go Cache Path Evidence' 19)$(STEP_OK 'Setup Node.js for Agent Runtime Packaging' 20)$(STEP_OK 'Custom Packages and Agent Runtimes' 21)$(STEP_OK 'Inject Private Firmware Configuration' 22)$(STEP_OK 'Custom Settings' 23)$(STEP_OK 'Guard Expected Device Config' 24)$(STEP_OK 'Download Packages' 25)$(STEP_OK 'Reserve Disk Space Before Compile' 26)"

echo "===== 1) Compile Firmware active, 120 min, log still updating ====="
export FAKE_RUN_9001="$(run_json in_progress null '2026-09-09T05:42:04Z' '2026-09-09T07:40:00Z' "$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")")"
export FAKE_JOBS_9001="$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")"
export FAKE_LOG_102352052803="$COMPILE_LOG"
OUT=$(run_monitor '2026-09-09T07:42:00Z' 9001)
echo "$OUT"
echo "$OUT" | grep -q 'verdicts=9001:building' && ok "120min compile with live log -> building" || bad "expected building, got: $OUT"
echo "$OUT" | grep -q 'flash=no' && ok "single building run -> flash=no" || bad "expected flash=no"

echo ""
echo "===== 2) Compile Firmware active, 180 min, job in_progress ====="
export FAKE_RUN_9002="$(run_json in_progress null '2026-09-09T05:42:04Z' '2026-09-09T08:35:00Z' "$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")")"
export FAKE_JOBS_9002="$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")"
export FAKE_LOG_102352052803="$COMPILE_LOG"
OUT=$(run_monitor '2026-09-09T08:42:00Z' 9002)
echo "$OUT"
echo "$OUT" | grep -q 'verdicts=9002:building' && ok "180min compile still in_progress -> building (no duration cancel)" || bad "expected building, got: $OUT"

echo ""
echo "===== 3) Initialization Environment beyond workflow timeout ====="
export FAKE_RUN_9003="$(run_json completed failure '2026-09-09T05:42:04Z' '2026-09-09T06:40:00Z' "$(jobs_json completed "$(STEP_OK 'Set up job' 1)$(STEP_OK 'Install BC' 2)$(STEP_FAIL 'Initialization Environment' 6)")")"
export FAKE_JOBS_9003="$(jobs_json completed "$(STEP_OK 'Set up job' 1)$(STEP_OK 'Install BC' 2)$(STEP_FAIL 'Initialization Environment' 6)")"
OUT=$(run_monitor '2026-09-09T08:42:00Z' 9003)
echo "$OUT"
echo "$OUT" | grep -q 'verdicts=9003:failure' && ok "IE failure -> failure" || bad "expected failure, got: $OUT"
echo "$OUT" | grep -q 'flash=no' && ok "failed run -> flash=no" || bad "expected flash=no"

echo ""
echo "===== 4) runner lost while compiling ====="
export FAKE_RUN_9004="$(run_json completed failure '2026-09-09T05:42:04Z' '2026-09-09T07:14:34Z' "$(jobs_json completed "${BASE_STEPS_OK}$(STEP_FAIL 'Compile Firmware' 27)")")"
export FAKE_JOBS_9004="$(jobs_json completed "${BASE_STEPS_OK}$(STEP_FAIL 'Compile Firmware' 27)")"
OUT=$(run_monitor '2026-09-09T08:42:00Z' 9004)
echo "$OUT"
echo "$OUT" | grep -q 'verdicts=9004:failure' && ok "runner lost (failure) -> failure" || bad "expected failure, got: $OUT"

echo ""
echo "===== 4b) in_progress compile + lost-communication log -> failure (explicit beats building) ====="
export FAKE_RUN_9005="$(run_json in_progress null '2026-09-09T05:42:04Z' '2026-09-09T07:13:00Z' "$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")")"
export FAKE_JOBS_9005="$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")"
export FAKE_LOG_102352052803="$LOST_LOG"
OUT=$(run_monitor '2026-09-09T07:42:00Z' 9005)
echo "$OUT"
echo "$OUT" | grep -q 'verdicts=9005:failure' && ok "lost-communication marker -> failure" || bad "expected failure, got: $OUT"

echo ""
echo "===== 5) completed/success ====="
export FAKE_RUN_9006="$(run_json completed success '2026-09-09T05:42:04Z' '2026-09-09T07:50:00Z' "$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)$(STEP_OK 'Save Build Cache' 30)")")"
export FAKE_JOBS_9006="$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)$(STEP_OK 'Save Build Cache' 30)")"
OUT=$(run_monitor '2026-09-09T08:42:00Z' 9006)
echo "$OUT"
echo "$OUT" | grep -q 'verdicts=9006:success' && ok "completed success -> success" || bad "expected success, got: $OUT"
echo "$OUT" | grep -q 'flash=yes' && ok "single success run -> flash=yes" || bad "expected flash=yes"

echo ""
echo "===== 6) completed/cancelled ====="
export FAKE_RUN_9007="$(run_json completed cancelled '2026-09-09T05:42:04Z' '2026-09-09T07:14:34Z' "$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)")")"
export FAKE_JOBS_9007="$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)")"
OUT=$(run_monitor '2026-09-09T08:42:00Z' 9007)
echo "$OUT"
echo "$OUT" | grep -q 'verdicts=9007:cancelled' && ok "completed cancelled -> cancelled" || bad "expected cancelled, got: $OUT"
echo "$OUT" | grep -q 'flash=no' && ok "cancelled run -> flash=no (never flash a cancelled run)" || bad "expected flash=no"

echo ""
echo "===== 7) two runs, not all success -> flash=no ====="
OUT=$(run_monitor '2026-09-09T08:42:00Z' 9006 9007)
echo "$OUT"
echo "$OUT" | grep -q 'flash=no' && ok "success+cancelled pair -> flash=no (both must be success)" || bad "expected flash=no"
echo "$OUT" | grep -q 'verdicts=9006:success,9007:cancelled' && ok "verdicts combined correctly" || bad "verdicts line wrong: $OUT"

echo ""
echo "===== 8) historical replay: 34315933534 + 34315937551 ====="
# 75-min moment: both in_progress, Compile Firmware active, make in log
export FAKE_RUN_34315933534="$(run_json in_progress null '2026-09-09T05:42:00Z' '2026-09-09T06:55:00Z' "$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")")"
export FAKE_JOBS_34315933534="$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")"
export FAKE_RUN_34315937551="$(run_json in_progress null '2026-09-09T05:42:04Z' '2026-09-09T06:55:00Z' "$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")")"
export FAKE_JOBS_34315937551="$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")"
export FAKE_LOG_102352052803="$COMPILE_LOG"
OUT=$(run_monitor '2026-09-09T06:57:00Z' 34315933534 34315937551)
echo "$OUT"
echo "$OUT" | grep -q '34315933534:building' && ok "historical run 34315933534 @75min -> building (was wrongly cancelled)" || bad "expected building for 34315933534: $OUT"
echo "$OUT" | grep -q '34315937551:building' && ok "historical run 34315937551 @75min -> building (was wrongly cancelled)" || bad "expected building for 34315937551: $OUT"
echo "$OUT" | grep -q 'flash=no' && ok "75min building pair -> flash=no, no cancel, no download" || bad "expected flash=no"

# terminal state: both cancelled
export FAKE_RUN_34315933534="$(run_json completed cancelled '2026-09-09T05:42:00Z' '2026-09-09T07:14:40Z' "$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)")")"
export FAKE_JOBS_34315933534="$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)")"
export FAKE_RUN_34315937551="$(run_json completed cancelled '2026-09-09T05:42:04Z' '2026-09-09T07:14:33Z' "$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)")")"
export FAKE_JOBS_34315937551="$(jobs_json completed "${BASE_STEPS_OK}$(STEP_OK 'Compile Firmware' 27)")"
OUT=$(run_monitor '2026-09-09T08:42:00Z' 34315933534 34315937551)
echo "$OUT"
echo "$OUT" | grep -q '34315933534:cancelled,34315937551:cancelled' && ok "terminal state -> both cancelled" || bad "expected both cancelled: $OUT"
echo "$OUT" | grep -q 'flash=no' && ok "cancelled pair -> flash=no, no firmware download" || bad "expected flash=no"

echo ""
echo "===== 9) no-change silence ====="
export FAKE_RUN_9008="$(run_json in_progress null '2026-09-09T05:42:04Z' '2026-09-09T07:40:00Z' "$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")")"
export FAKE_JOBS_9008="$(jobs_json in_progress "${BASE_STEPS_OK}$(STEP_RUN 'Compile Firmware' 27)")"
export FAKE_LOG_102352052803="$COMPILE_LOG"
OUT1=$(run_monitor '2026-09-09T07:42:00Z' 9008)
OUT2=$(run_monitor '2026-09-09T07:57:00Z' 9008)
echo "tick1: $(echo "$OUT1" | grep '^event=')"
echo "tick2: $(echo "$OUT2" | grep '^event=')"
echo "$OUT1" | grep -q '^event=progress' && ok "first tick emits progress" || bad "expected progress on first tick"
echo "$OUT2" | grep -q '^event=no-change' && ok "second identical tick stays silent (no-change)" || bad "expected no-change on second tick"

echo ""
echo "=========================================="
echo "ci run monitor test: PASS=$PASS FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
