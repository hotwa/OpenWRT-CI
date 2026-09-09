#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT="$ROOT/files-container-runtime-test/etc/init.d/containerd-test"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_case() (
    local scenario="$1" expected="$2" setting="${3-0}"
    local events='' rc=0
    # Source only function declarations; no service or host files are changed.
    source "$INIT"
    logger() { events+="log:$*"$'\n'; }
    data_mount_ready() { events+=$'data\n'; [[ "$scenario" != data-fail ]]; }
    cgroup_ready() { events+=$'cgroup\n'; [[ "$scenario" != cgroup-fail ]]; }
    runtime_binaries_ready() { events+=$'binaries\n'; [[ "$scenario" != binary-fail ]]; }
    prepare_runtime_dirs() { events+=$'prepare\n'; [[ "$scenario" != prepare-fail ]]; }
    # Mock the OS executable check, not bridge policy control flow.
    [() {
        if [[ "${1-}" == -x && "${2-}" == /usr/sbin/container-bridge-nft ]]; then
            [[ "$scenario" != missing && "$scenario" != nonexecutable ]]
        else
            builtin [ "$@"
        fi
    }
    /usr/sbin/container-bridge-nft() {
        events+="bridge:$*"$'\n'
        [[ "$scenario" != bridge-fail ]]
    }
    uci() {
        [[ "$*" == '-q get containerd-test.main.run_without_bridge' ]] || return 1
        [[ "$setting" != missing ]] || return 1
        printf '%s\n' "$setting"
    }
    procd_open_instance() { events+=$'daemon\n'; }
    procd_set_param() { events+="procd:$*"$'\n'; }
    procd_close_instance() { events+=$'close\n'; }
    start_service || rc=$?
    if [[ "$expected" == start ]]; then
        [[ "$events" == *$'daemon\n'* ]] || fail "$scenario/$setting: daemon did not start ($events)"
        [[ "$events" == *'command /usr/bin/containerd --config /etc/containerd/containerd-test.toml'* ]] || fail 'daemon command changed'
    else
        [[ "$events" != *$'daemon\n'* ]] || fail "$scenario/$setting: daemon started despite gate"
    fi
    if [[ "$scenario" == success ]]; then
        [[ "$events" == *$'bridge:enable\n'*$'daemon\n'* ]] || fail 'bridge must be enabled before daemon'
        [[ "$events" == *'default container bridge enabled'* ]] || fail 'missing bridge success log'
    elif [[ "$scenario" == bridge-fail || "$scenario" == missing || "$scenario" == nonexecutable ]]; then
        if [[ "$scenario" != bridge-fail ]]; then
            [[ "$events" != *'bridge:enable'* ]] || fail 'unavailable helper must not execute'
            [[ "$events" == *'missing or not executable'* ]] || fail 'missing helper reason must be logged'
        fi
        if [[ "$setting" == 1 ]]; then
            [[ "$events" == *WARNING*'stale CNI'*'Nikki network policy'*'not guaranteed'* ]] || fail 'escape warning must explain risk'
            [[ "$events" == *'no network isolation is promised'* ]] || fail 'escape must not promise isolation'
        else
            [[ "$events" == *'refusing to start:'* ]] || fail 'bridge rejection must be visible'
        fi
    else
        [[ "$events" != *'bridge:enable'* ]] || fail 'hard prerequisite must reject before bridge enable'
        [[ "$events" != *$'daemon\n'* ]] || fail 'escape bypassed hard prerequisite'
    fi
    [[ "$events" != *compose* ]] || fail 'init must not launch compose'
    [[ "$scenario" != prepare-fail || "$rc" != 0 ]] || fail 'directory preparation failure must propagate'
)

run_case success start
for scenario in bridge-fail missing nonexecutable; do
    for setting in 0 missing '' true yes 01 2 '1 '; do
        run_case "$scenario" inactive "$setting"
    done
    run_case "$scenario" start 1
done
for scenario in data-fail cgroup-fail binary-fail prepare-fail; do
    run_case "$scenario" inactive 1
done
# Exercise the actual hard-prerequisite functions against host-shell fixtures.
(
    source "$INIT"
    logger() { :; }
    for missing_binary in /usr/bin/containerd /usr/bin/containerd-shim-runc-v2 /usr/bin/ctr /usr/bin/nerdctl /usr/sbin/runc; do
        [() {
            if [[ "${1-}" == -x ]]; then
                [[ "$2" != "$missing_binary" ]]
            else
                builtin [ "$@"
            fi
        }
        if runtime_binaries_ready; then fail "missing $missing_binary was accepted"; fi
    done
    for fixture in '/dev/sda1 /data ext4 rw 0 0' '/dev/sda1 /data f2fs rw 0 0'; do
        awk() { printf '%s\n' "$fixture" | command awk "$1"; }
        data_mount_ready || fail "valid data mount rejected: $fixture"
    done
    for fixture in 'tmpfs /data tmpfs rw 0 0' '/dev/sda1 /other ext4 rw 0 0' '/dev/sda1 /data btrfs rw 0 0' 'overlay /data ext4 rw 0 0'; do
        if data_mount_ready; then fail "invalid data mount accepted: $fixture"; fi
    done
)
grep -q '^START=95$' "$INIT" || fail 'service order must remain 95'
if grep -Eq 'nerdctl[[:space:]]+compose|docker[[:space:]]+compose' "$INIT"; then fail 'init must not launch compose'; fi
grep -q "option run_without_bridge '0'" "$ROOT/files-container-runtime-test/etc/config/containerd-test" || fail 'escape must default off'
printf 'PASS: containerd-test init bridge gate and explicit escape\n'
