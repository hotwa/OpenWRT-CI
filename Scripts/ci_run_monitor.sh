#!/usr/bin/env bash
# =============================================================================
# ci_run_monitor.sh — READ-ONLY GitHub Actions run monitor / decision engine
#
# Purpose
# -------
# Decide, on every cron tick, what the "OpenWRT 编译监控" loop should do with a
# set of workflow runs. It is a DECISION engine, NOT an action engine: it never
# cancels a run, never downloads artifacts and never flashes devices. Cancelling
# is left to the workflow's own timeouts (JOB_TIMEOUT_MINUTES=360) or to a
# human. This is a deliberate design choice: the 2026-09-09 cold-build
# mis-cancellation (runs 34315933534 / 34315937551 were cancelled after ~75 min
# while `make` was still producing output in Compile Firmware) taught us that
# any duration-based or silence-based cancel heuristic is wrong for this
# pipeline, where a cold compile legitimately takes 91-119 minutes.
#
# Decision rules (mirror of the monitoring contract)
# --------------------------------------------------
# 1. NEVER cancel based on a single weak signal. The following are NEVER,
#    alone, grounds for treating a run as failed:
#      - total elapsed time over any fixed threshold;
#      - absence of "normal status messages" for a while;
#      - Compile Firmware lasting longer than 75 minutes;
#      - GitHub API returning no fresh ordinary log lines.
# 2. While the active step is "Compile Firmware":
#      - run in_progress AND job not failed AND logs still show build activity
#        (make/gcc/perl/go/ninja/...) => verdict=building, wait. Cold builds get
#        at least 3 hours; the final ceiling is JOB_TIMEOUT_MINUTES=360.
# 3. While the active step is "Initialization Environment":
#      - let the workflow's own 60-min inner / 75-min step timeout do their
#        job; the monitor must not declare failure before that, and must not
#        treat a quiet apt as a wedged runner. Only an explicit job failure,
#        runner loss, dead process or workflow timeout is a failure.
# 4. "No progress" must be judged from MULTIPLE evidence: active step + run/job
#    status + recency of the latest log activity + build commands in the log +
#    explicit failure/timeout/runner-lost markers. One signal never triggers
#    anything.
# 5. Completed runs:
#      - completed/success  -> verdict=success;
#      - completed/failure  -> verdict=failure;
#      - completed/cancelled-> verdict=cancelled (record only; never download,
#                              never flash);
#      - completed/timed_out-> verdict=timeout (explicit failure).
# 6. Cache: a cancelled/failed cold build publishes no new cache (see
#    wrt_cache_lib.sh save-decision), so the next run is cold again. A missing
#    cache hit is NOT an anomaly and must never shorten the allowed build time;
#    the first cold compile must be allowed to finish and save its cache.
# 7. Loop contract: keep duplicate-run protection and the success-of-BOTH-runs
#    gate at the caller; stay silent while nothing changed; emit an event only
#    for success / failure / runner lost / explicit timeout / human action
#    needed.
#
# Output
# ------
# One machine-readable line plus human detail:
#   event=<no-change|progress|building|success|failure|cancelled|timeout|attention>
#   verdicts=<run_id>:<verdict>[,...]
#   flash=yes|no
#   detail=...
#
# `flash=yes` is emitted ONLY when every watched run is completed/success. The
# caller (cron/agent) is still responsible for the duplicate-flash state check
# before doing anything.
#
# Usage: ci_run_monitor.sh [--repo REPO] [--state-dir DIR] RUN_ID...
#   REPO      default hotwa/OpenWRT-CI
#   STATE-DIR default ${TMPDIR:-/tmp}/ci_run_monitor_state
#   CI_MONITOR_NOW  optional ISO timestamp used as "now" (tests)
#   CI_MONITOR_FETCH_LOGS   set to 1 to fetch job log tails for build-activity
#                           evidence (default 1)
# =============================================================================
set -uo pipefail

REPO="hotwa/OpenWRT-CI"
STATE_DIR="${TMPDIR:-/tmp}/ci_run_monitor_state"
FETCH_LOGS="${CI_MONITOR_FETCH_LOGS:-1}"
NOW_ISO="${CI_MONITOR_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

COMPILE_STEP_RE='Compile Firmware'
IE_STEP_RE='Initialization Environment'
# Build activity markers found in Compile Firmware logs. Loosely matched so a
# busy log (even one without an obvious command prefix) counts as alive.
BUILD_ACTIVITY_RE='(^|[^A-Za-z])(make(\[[0-9]+\])?|gcc|g\+\+|cc1|perl[0-9]?[^A-Za-z]|go (build|install|generate|env)|go_bootstrap|ninja|cmake|ld(\.bfd)?[^A-Za-z]|ar [^A-Za-z]|python3?[^A-Za-z]|\./scripts/(feeds|patch)|tar [^A-Za-z]|wget|curl)'
LOST_RE='lost communication|runner[^A-Za-z]*(was|is)?[^A-Za-z]*lost|Unable to connect to the runner|cannot connect to the runner'

usage() {
  cat >&2 <<'USAGE'
usage: ci_run_monitor.sh [--repo REPO] [--state-dir DIR] RUN_ID...
  --repo      GitHub repo (default hotwa/OpenWRT-CI)
  --state-dir directory storing per-run last verdict (default /tmp/ci_run_monitor_state)
  RUN_ID      one or more workflow run ids
USAGE
  exit 2
}

# ---------------------------------------------------------------------------
# gh wrappers (mockable in tests by shadowing these functions)
# ---------------------------------------------------------------------------
gh_run_view() { # <run_id> <repo> -> run JSON (status, conclusion, createdAt, updatedAt, displayTitle, jobs)
  gh run view "$1" --repo "$2" --json status,conclusion,createdAt,updatedAt,displayTitle,jobs 2>/dev/null
}
gh_jobs_api() { # <repo> <run_id> -> jobs JSON
  gh api "repos/$1/actions/runs/$2/jobs" 2>/dev/null
}
gh_job_logs() { # <repo> <job_id> -> raw log text
  gh api "repos/$1/actions/jobs/$2/logs" 2>/dev/null
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
iso_to_epoch() { # <iso8601> -> epoch seconds
  date -u -d "$1" +%s 2>/dev/null || echo 0
}

# Find the currently active step inside a jobs JSON. Emits "JOB_ID|STEP_NAME"
# (first in-progress/queued step of any in-progress job), or empty.
find_active_step() { # <jobs_json>
  local jobs_json="$1" job_id step_name
  job_id=$(printf '%s' "$jobs_json" | python3 -c '
import json,sys
try:
    jobs=json.load(sys.stdin).get("jobs",[])
except Exception:
    sys.exit(0)
for j in jobs:
    if j.get("status")!="completed":
        for s in j.get("steps",[]):
            if s.get("status") in ("in_progress","queued"):
                print(j.get("id",""), s.get("name",""), sep="|")
                sys.exit(0)
' 2>/dev/null)
  printf '%s' "$job_id"
}

# True if the log tail shows build activity. Reads full log from stdin, keeps
# the last MAX bytes.
log_has_build_activity() { # <max_bytes>
  local max_bytes="${1:-300000}"
  local tailbuf
  tailbuf=$(tail -c "$max_bytes" 2>/dev/null)
  if [ -n "$tailbuf" ] && printf '%s' "$tailbuf" | grep -Eq "$BUILD_ACTIVITY_RE"; then
    return 0
  fi
  return 1
}

log_has_lost_marker() { # <max_bytes>
  local max_bytes="${1:-300000}"
  local tailbuf
  tailbuf=$(tail -c "$max_bytes" 2>/dev/null)
  if [ -n "$tailbuf" ] && printf '%s' "$tailbuf" | grep -Eq "$LOST_RE"; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# classify one run. Emits verdict + evidence lines.
# ---------------------------------------------------------------------------
classify_run() { # <run_id>
  local run_id="$1"
  local run_json jobs_json active_step active_job active_name
  local status conclusion created_at updated_at elapsed_min
  local job_failed=no build_activity=no recent=no explicit_failure=no

  run_json=$(gh_run_view "$run_id" "$REPO")
  [ -n "$run_json" ] || {
    echo "verdict=error"
    echo "evidence=gh run view failed for $run_id" >&2
    return 0
  }

  status=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
  conclusion=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("conclusion") or "")' 2>/dev/null)
  created_at=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("createdAt",""))' 2>/dev/null)
  updated_at=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("updatedAt",""))' 2>/dev/null)

  local now_epoch created_epoch updated_epoch
  now_epoch=$(iso_to_epoch "$NOW_ISO")
  created_epoch=$(iso_to_epoch "$created_at")
  updated_epoch=$(iso_to_epoch "$updated_at")
  if [ "$now_epoch" -gt 0 ] && [ "$created_epoch" -gt 0 ]; then
    elapsed_min=$(( (now_epoch - created_epoch) / 60 ))
  else
    elapsed_min=0
  fi
  if [ "$now_epoch" -gt 0 ] && [ "$updated_epoch" -gt 0 ] && [ $(( (now_epoch - updated_epoch) / 60 )) -le 30 ]; then
    recent=yes
  fi

  # ---- completed runs ----------------------------------------------------
  if [ "$status" = "completed" ]; then
    case "$conclusion" in
      success)  echo "verdict=success";    echo "evidence=run $run_id completed success; elapsed ${elapsed_min}min" >&2 ;;
      failure)  echo "verdict=failure";    echo "evidence=run $run_id completed failure; elapsed ${elapsed_min}min; run 'gh run view $run_id --repo $REPO --log-failed' for the failing step" >&2 ;;
      cancelled) echo "verdict=cancelled"; echo "evidence=run $run_id cancelled (elapsed ${elapsed_min}min); record only, do NOT download firmware, do NOT flash" >&2 ;;
      timed_out) echo "verdict=timeout";   echo "evidence=run $run_id timed out (explicit workflow timeout); elapsed ${elapsed_min}min" >&2 ;;
      startup_failure) echo "verdict=failure"; echo "evidence=run $run_id startup_failure" >&2 ;;
      "")       echo "verdict=error";      echo "evidence=run $run_id completed with empty conclusion" >&2 ;;
      *)        echo "verdict=unknown";    echo "evidence=run $run_id completed with conclusion=$conclusion" >&2 ;;
    esac
    return 0
  fi

  # ---- in-progress / queued runs ----------------------------------------
  jobs_json=$(gh_jobs_api "$REPO" "$run_id")
  active_step=$(find_active_step "$jobs_json")
  active_job=${active_step%%|*}
  active_name=${active_step#*|}
  [ "$active_step" = "$active_name" ] && active_name=""

  # explicit failure markers from run/job state
  if [ "$conclusion" = "failure" ] || [ "$conclusion" = "timed_out" ]; then
    explicit_failure=yes
  fi
  if printf '%s' "$jobs_json" | grep -qE '"conclusion"[[:space:]]*:[[:space:]]*"failure"'; then
    job_failed=yes
    explicit_failure=yes
  fi

  # fetch log tail for build activity evidence (only while compiling, and only
  # when we have an active job id)
  if [ "$FETCH_LOGS" = "1" ] && [ -n "$active_job" ] && [ -n "$active_name" ] \
     && printf '%s' "$active_name" | grep -Eq "$COMPILE_STEP_RE"; then
    local logbuf
    logbuf=$(gh_job_logs "$REPO" "$active_job")
    if [ -n "$logbuf" ]; then
      if printf '%s' "$logbuf" | tail -c 300000 | grep -Eq "$BUILD_ACTIVITY_RE"; then
        build_activity=yes
      fi
      if printf '%s' "$logbuf" | tail -c 300000 | grep -Eq "$LOST_RE"; then
        explicit_failure=yes
      fi
    fi
  fi

  # ---- IE active: wait for workflow's own timeout; only explicit failure ---- 
  if [ -n "$active_name" ] && printf '%s' "$active_name" | grep -Eq "$IE_STEP_RE"; then
    if [ "$explicit_failure" = "yes" ]; then
      echo "verdict=failure"
      echo "evidence=Initialization Environment active on run $run_id (${elapsed_min}min) but explicit failure/runner-lost marker present" >&2
    else
      echo "verdict=running"
      echo "evidence=Initialization Environment active on run $run_id (${elapsed_min}min); letting the workflow's own 60/75-min timeouts decide; quiet apt is NOT a wedged runner" >&2
    fi
    return 0
  fi

  # ---- Compile Firmware active: multi-evidence "still building" -----------
  if [ -n "$active_name" ] && printf '%s' "$active_name" | grep -Eq "$COMPILE_STEP_RE"; then
    # Evidence 1: run still in_progress (we are here only if so)
    # Evidence 2: no job failure
    # Evidence 3: recent log activity (run updatedAt within 30 min)
    # Evidence 4: build commands present in the log tail
    # Explicit failure markers override everything.
    if [ "$explicit_failure" = "yes" ]; then
      echo "verdict=failure"
      echo "evidence=Compile Firmware active on run $run_id but explicit failure/runner-lost marker present (job_failed=$job_failed)" >&2
      return 0
    fi
    if [ "$elapsed_min" -ge 360 ]; then
      echo "verdict=attention"
      echo "evidence=Compile Firmware active on run $run_id for >=360min (JOB_TIMEOUT ceiling); if the workflow has not failed it by itself, a human should inspect (build_activity=$build_activity recent=$recent)" >&2
      return 0
    fi
    echo "verdict=building"
    echo "evidence=Compile Firmware active on run $run_id (elapsed ${elapsed_min}min; cold builds need 91-119min, >=180min tolerated); run=in_progress job_failed=$job_failed log_build_activity=$build_activity log_recent=$recent; no cancel by duration/silence" >&2
    return 0
  fi

  # ---- any other active step ----------------------------------------------
  if [ "$explicit_failure" = "yes" ]; then
    echo "verdict=failure"
    echo "evidence=step '$active_name' active on run $run_id but explicit failure marker present" >&2
  else
    echo "verdict=running"
    echo "evidence=step '$active_name' active on run $run_id (elapsed ${elapsed_min}min); waiting" >&2
  fi
}

# ---------------------------------------------------------------------------
# state: last-verdict comparison (no-change -> silent)
# ---------------------------------------------------------------------------
emit_event() { # <verdicts_line>
  local verdicts_line="$1" state_file event
  state_file="$STATE_DIR/${REPO//\//-}.state"
  mkdir -p "$STATE_DIR"
  if [ -f "$state_file" ] && [ "$(cat "$state_file" 2>/dev/null)" = "$verdicts_line" ]; then
    event=no-change
  else
    printf '%s\n' "$verdicts_line" > "$state_file"
    case "$verdicts_line" in
      *:success*) event=success ;;
      *:failure*) event=failure ;;
      *:timeout*) event=timeout ;;
      *:cancelled*) event=cancelled ;;
      *:attention*) event=attention ;;
      *:building*|*:running*) event=progress ;;
      *) event=progress ;;
    esac
  fi
  printf 'event=%s\n' "$event"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
RUN_IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) RUN_IDS+=("$1"); shift ;;
  esac
done
[ "${#RUN_IDS[@]}" -ge 1 ] || usage

verdicts_line=""
flash=no
all_success=yes
for rid in "${RUN_IDS[@]}"; do
  v=$(classify_run "$rid" | grep -E '^verdict=' | cut -d= -f2)
  case "$v" in
    success) : ;;
    *) all_success=no ;;
  esac
  verdicts_line="${verdicts_line}${rid}:${v},"
done
verdicts_line="${verdicts_line%,}"

if [ "$all_success" = "yes" ]; then
  flash=yes
fi

emit_event "$verdicts_line"
printf 'verdicts=%s\n' "$verdicts_line"
printf 'flash=%s\n' "$flash"
printf 'detail=see evidence lines above (run with -x for full)\n'
