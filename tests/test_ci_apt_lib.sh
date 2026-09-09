#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# test_ci_apt_lib.sh 鈥?focused tests for Scripts/ci-apt-lib.sh:
#   * mirror normalization (legacy .list AND deb822 .sources; any mirror
#     domain; archive vs security split; third-party PPA untouched)
#   * aptx uses apt-get, is non-interactive, bounded per-command timeout
#   * aptx_retry obeys APT_MAX_RETRIES (no unbounded nesting)
#   * aptx_update falls back to the official archives exactly once
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/Scripts/ci-apt-lib.sh"

[ -f "$LIB" ] || { echo "missing ci-apt-lib.sh"; exit 1; }
bash -n "$LIB" || { echo "ci-apt-lib.sh does not parse"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1) mirror normalization: legacy .list
# ---------------------------------------------------------------------------
APT_ROOT="$TMP/legacy"
mkdir -p "$APT_ROOT/sources.list.d" "$APT_ROOT/lists"
cat > "$APT_ROOT/sources.list" <<'EOF'
deb http://mirrors.cloud.tencent.com/ubuntu/ jammy main restricted
deb http://security.ubuntu.com/ubuntu jammy-security main
deb-src http://mirrors.ustc.edu.cn/ubuntu jammy-updates main
deb [arch=amd64] http://archive.ubuntu.com/ubuntu jammy universe
deb http://ppa.launchpad.net/foo/bar/ubuntu jammy main
EOF

SUDO=""
. "$LIB"
reset_ubuntu_mirrors "$APT_ROOT" >/dev/null 2>&1

grep -q '^deb https://archive\.ubuntu\.com/ubuntu jammy main restricted$' "$APT_ROOT/sources.list" \
  || fail "legacy: tencent mirror not normalized to archive.ubuntu.com"
grep -q '^deb https://security\.ubuntu\.com/ubuntu jammy-security main$' "$APT_ROOT/sources.list" \
  || fail "legacy: security source lost"
grep -q '^deb-src https://archive\.ubuntu\.com/ubuntu jammy-updates main$' "$APT_ROOT/sources.list" \
  || fail "legacy: ustc deb-src not normalized"
grep -Fq 'deb [arch=amd64] https://archive.ubuntu.com/ubuntu jammy universe' "$APT_ROOT/sources.list" \
  || fail "legacy: official archive with options mangled"
grep -q '^deb http://ppa\.launchpad\.net/foo/bar/ubuntu jammy main$' "$APT_ROOT/sources.list" \
  || fail "legacy: third-party PPA must be left untouched"

# ---------------------------------------------------------------------------
# 2) mirror normalization: deb822 .sources (two stanzas, archive + security)
# ---------------------------------------------------------------------------
APT_ROOT="$TMP/deb822"
mkdir -p "$APT_ROOT/sources.list.d" "$APT_ROOT/lists"
cat > "$APT_ROOT/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://mirrors.aliyun.com/ubuntu/
Suites: jammy jammy-updates jammy-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://mirrors.cloud.tencent.com/ubuntu/
Suites: jammy-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
cat > "$APT_ROOT/sources.list.d/runner.sources" <<'EOF'
Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

reset_ubuntu_mirrors "$APT_ROOT" >/dev/null 2>&1

grep -q '^URIs: https://archive\.ubuntu\.com/ubuntu$' "$APT_ROOT/sources.list.d/ubuntu.sources" \
  || fail "deb822: archive stanza not normalized"
grep -q '^URIs: https://security\.ubuntu\.com/ubuntu$' "$APT_ROOT/sources.list.d/ubuntu.sources" \
  || fail "deb822: security stanza not normalized to security.ubuntu.com"
# GitHub runner mirror+file mechanism must be replaced with official archives
# (a partial mirror silently leaves the main-suite index missing).
grep -q '^URIs: https://archive\.ubuntu\.com/ubuntu$' "$APT_ROOT/sources.list.d/runner.sources" \
  || fail "deb822: mirror+file archive stanza not normalized to official archive"
grep -q '^URIs: https://security\.ubuntu\.com/ubuntu$' "$APT_ROOT/sources.list.d/runner.sources" \
  || fail "deb822: mirror+file security stanza not normalized to security.ubuntu.com"
grep -q 'mirror+file:' "$APT_ROOT/sources.list.d/runner.sources" \
  && fail "deb822: mirror+file must be fully replaced"
# deb822 stanzas must stay separated by a blank line: apt silently drops the
# first (archive) stanza when the separator is collapsed.
grep -q '^$' "$APT_ROOT/sources.list.d/ubuntu.sources" \
  || fail "deb822: stanza separator blank line lost (apt drops archive stanza)"
grep -q '^$' "$APT_ROOT/sources.list.d/runner.sources" \
  || fail "deb822: runner.sources stanza separator blank line lost"

# ---------------------------------------------------------------------------
# 3) aptx uses apt-get (never `apt`), non-interactive, bounded retries
# ---------------------------------------------------------------------------
FAKE="$TMP/fakebin"
mkdir -p "$FAKE"
cat > "$FAKE/apt-get" <<'EOF'
#!/bin/bash
echo "$@" >> "$CALL_LOG"
exit "${APT_FAKE_RC:-0}"
EOF
chmod +x "$FAKE/apt-get"

export CALL_LOG="$TMP/calls1.log"
export APT_FAKE_RC=0
PATH="$FAKE:$PATH"
SUDO=""
APT_CMD_TIMEOUT=5
. "$LIB"
aptx update
grep -q -- '-y' "$CALL_LOG" || fail "aptx did not pass -y (non-interactive)"
grep -q -- '-o Acquire::Retries=2' "$CALL_LOG" || fail "aptx did not bound Acquire::Retries to 2"
grep -q -- '-o Acquire::http::Timeout=30' "$CALL_LOG" || fail "aptx did not set http timeout"
grep -q ' update$' "$CALL_LOG" || fail "aptx did not forward the apt subcommand"

# ---------------------------------------------------------------------------
# 4) aptx_retry obeys APT_MAX_RETRIES 鈥?never unbounded nesting
# ---------------------------------------------------------------------------
export CALL_LOG="$TMP/calls2.log"
export APT_FAKE_RC=1
APT_MAX_RETRIES=2
set +e
aptx_retry update >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "aptx_retry must fail after exhausting attempts"
CALLS=$(wc -l < "$CALL_LOG")
[ "$CALLS" -eq 2 ] || fail "aptx_retry made $CALLS calls, expected 2 (APT_MAX_RETRIES=2)"

# ---------------------------------------------------------------------------
# 5) aptx_update: exactly one fallback to official archives
# ---------------------------------------------------------------------------
CALL_LOG="$TMP/calls3.log"
APT_ROOT="$TMP/deb822"
cat > "$FAKE/apt-get" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$COUNT_FILE"
if [ "$n" -eq 1 ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$FAKE/apt-get"
export COUNT_FILE="$TMP/count"
unset CALL_LOG  # fake apt-get for this case does not append to CALL_LOG

set +e
aptx_update >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "aptx_update should succeed on the official-archive fallback attempt"
[ "$(cat "$COUNT_FILE")" -eq 2 ] || fail "aptx_update made $(cat "$COUNT_FILE") update attempts, expected exactly 2 (1 fail + 1 fallback)"

# ---------------------------------------------------------------------------
# 6) WRT-CORE.yml / ci_init_environment.sh wiring guards
# ---------------------------------------------------------------------------
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
INIT_ENV="$ROOT_DIR/Scripts/ci_init_environment.sh"
[ -f "$WORKFLOW" ] || fail "missing WRT-CORE.yml"
[ -f "$INIT_ENV" ] || fail "missing ci_init_environment.sh"

grep -q 'timeout --kill-after=30 3600 bash "\$GITHUB_WORKSPACE/Scripts/ci_init_environment.sh"' "$WORKFLOW" \
  || fail "WRT-CORE.yml does not wrap the whole IE bootstrap in the 60min hard bound"
grep -q 'ci-apt-lib.sh' "$INIT_ENV" \
  || fail "ci_init_environment.sh does not source the shared apt library"
grep -q 'aptx_update' "$INIT_ENV" \
  || fail "ci_init_environment.sh does not use the bounded apt update"
grep -q 'init_build_environment.sh' "$INIT_ENV" \
  || fail "ci_init_environment.sh does not run init_build_environment.sh"

# ---------------------------------------------------------------------------
# 7) mirror normalization goes through sudo on a non-root runner
#    (reset_ubuntu_mirrors must actually modify /etc/apt-like files)
# ---------------------------------------------------------------------------
if command -v sudo >/dev/null 2>&1; then
  APT_ROOT="$TMP/sudopath"
  mkdir -p "$APT_ROOT/sources.list.d" "$APT_ROOT/lists"
  printf 'deb http://mirrors.aliyun.com/ubuntu jammy main\n' > "$APT_ROOT/sources.list"

  SUDO="sudo -E"
  set +e
  reset_ubuntu_mirrors "$APT_ROOT" >/dev/null 2>&1
  RC=$?
  set -e
  [ "$RC" -eq 0 ] || fail "reset_ubuntu_mirrors via sudo must succeed (rc=$RC)"
  grep -q '^deb https://archive\.ubuntu\.com/ubuntu jammy main$' "$APT_ROOT/sources.list" \
    || fail "sudo path: mirror was not normalized (file may not have been written)"
fi

# ---------------------------------------------------------------------------
# 8) non-root WITHOUT sudo must fail loudly, never silently no-op
#    (parent dir must be world-traversable or os.walk cannot even reach the
#    read-only files and the function would silently no-op). GitHub-hosted
#    Actions steps run as the non-root `runner` user, so `runuser` cannot be
#    invoked directly there; use passwordless sudo only to enter the `nobody`
#    shell. SUDO remains empty inside that shell so the function itself is
#    still tested without sudo.
# ---------------------------------------------------------------------------
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  RO_ROOT="$(mktemp -d)"
  chmod 0755 "$RO_ROOT"
  APT_ROOT="$RO_ROOT/ro"
  mkdir -p "$APT_ROOT/sources.list.d" "$APT_ROOT/lists"
  printf 'deb http://mirrors.cloud.tencent.com/ubuntu jammy main\n' > "$APT_ROOT/sources.list"
  chmod -R a-w "$APT_ROOT"
  chmod 0555 "$APT_ROOT"
  # Copy the lib to a world-readable location: on GitHub runners /home/runner
  # is 0700, so `nobody` cannot `cd` into the checkout and a `cd $ROOT_DIR`
  # gate would silently exit 9 with no WARN, failing the loudness assertion.
  cp "$LIB" "$RO_ROOT/ci-apt-lib.sh"
  chmod 0644 "$RO_ROOT/ci-apt-lib.sh"

  set +e
  sudo -n -u nobody -- bash -c "
    . '$RO_ROOT/ci-apt-lib.sh'
    reset_ubuntu_mirrors '$APT_ROOT'
    exit \$?
  " >"$TMP/r8.log" 2>&1
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail "read-only non-root mirror normalization must return non-zero"
  grep -q 'WARN: mirror normalization failed' "$TMP/r8.log" \
    || fail "read-only non-root failure must be loud (WARN expected)"
  # Restore write permission before cleanup: chmod -R a-w also removed the
  # owner's write bit, and a bare `rm -rf` under a non-root Actions runner
  # then fails with EACCES (root hides this because CAP_DAC_OVERRIDE), which
  # set -e turns into a silent exit 1 right before the final PASS line.
  chmod -R u+w "$RO_ROOT" 2>/dev/null || true
  rm -rf "$RO_ROOT" 2>/dev/null || true
fi

echo "ci apt lib test passed"
