#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# ci-apt-lib.sh — single apt execution library for the GitHub Actions
# environment bootstrap (WRT-CORE.yml "Initialization Environment").
#
# Why a single library:
#   A stalled apt mirror previously wedged "Initialization Environment" for
#   ~1h15m until GitHub declared the hosted runner lost. The failure mode was
#   unbounded nested retries: Acquire::Retries=5 inside a 600s timeout, one
#   in-band retry, an outer 3x retry loop, and a second 3x retry loop after a
#   mirror reset that only matched two specific Chinese mirror domains. A slow
#   or unreachable mirror could therefore burn hours inside one step.
#
# Rules enforced here (source this file, then call aptx/aptx_retry/aptx_update):
#   * Every apt invocation goes through aptx() and uses `apt-get`, never the
#     interactive `apt` frontend.
#   * One command is bounded by APT_CMD_TIMEOUT (default 300s).
#   * apt-level retries are APT_ACQUIRE_RETRIES (default 2, was 5).
#   * aptx_retry() retries at most APT_MAX_RETRIES times (default 2) with a
#     fixed 15s sleep — no exponential, nested or unbounded loops.
#   * aptx_update() normalizes every Ubuntu mirror to the official HTTPS
#     archives BEFORE the first update, and falls back to the official
#     archives exactly once if the first attempt fails (it never retries the
#     same unreachable mirror forever).
#   * diagnose_apt() dumps sources, release, mirror DNS, dpkg/apt locks and
#     running apt/dpkg processes on failure so a held runner (CI Debug Gate)
#     can be debugged in place.
#
# Caller contract: set SUDO to "sudo -E" (when sudo exists) or "" (when
# running as root) before sourcing. No third-party apt sources are added.

: "${SUDO:=}"
: "${APT_CMD_TIMEOUT:=300}"
: "${APT_ACQUIRE_RETRIES:=2}"
: "${APT_MAX_RETRIES:=2}"

# ---------------------------------------------------------------------------
# aptx — run one apt-get command with a hard timeout and bounded apt retries.
# ---------------------------------------------------------------------------
aptx() {
	local rc=0
	# shellcheck disable=SC2086  # SUDO intentionally word-split ("sudo -E" / "")
	timeout "$APT_CMD_TIMEOUT" $SUDO apt-get -y \
		-o Dpkg::Use-Pty=0 \
		-o Acquire::Retries="$APT_ACQUIRE_RETRIES" \
		-o Acquire::http::Timeout=30 \
		-o Acquire::https::Timeout=30 \
		-o Acquire::ftp::Timeout=30 \
		"$@" || rc=$?
	return "$rc"
}

# ---------------------------------------------------------------------------
# aptx_retry — run aptx with at most APT_MAX_RETRIES attempts (default 2).
# Each attempt is independently bounded by APT_CMD_TIMEOUT, so the worst case
# is APT_MAX_RETRIES * APT_CMD_TIMEOUT plus sleeps — never unbounded.
# ---------------------------------------------------------------------------
aptx_retry() {
	local attempt=1 rc=0
	while [ "$attempt" -le "$APT_MAX_RETRIES" ]; do
		echo "== [apt] attempt $attempt/$APT_MAX_RETRIES: apt-get $* =="
		if aptx "$@"; then
			echo "== [apt] OK: apt-get $* =="
			return 0
		else
			# $? inside the else branch is aptx's exit code, NOT the
			# if-statement status (which would be 0 with no else body).
			rc=$?
		fi
		echo "WARN: apt-get $* failed (rc=$rc) on attempt $attempt/$APT_MAX_RETRIES" >&2
		[ "$attempt" -ge "$APT_MAX_RETRIES" ] && break
		sleep 15
		attempt=$((attempt + 1))
	done
	diagnose_apt "apt-get $*"
	return "$rc"
}

# ---------------------------------------------------------------------------
# reset_ubuntu_mirrors — normalize every Ubuntu archive/security source to the
# official HTTPS endpoints, whatever mirror domain is present.
#
#   * Supports legacy `deb` / `deb-src` lines in sources.list and
#     sources.list.d/*.list.
#   * Supports deb822 `URIs:`/`Suites:` stanzas in *.sources files (GitHub
#     ubuntu-latest runners use deb822).
#   * Matches ANY mirror domain whose path is /ubuntu or /ubuntu-security
#     (a single path segment) — not just mirrors.cloud.tencent.com /
#     mirrors.ustc.edu.cn. Multi-segment third-party paths such as
#     ppa.launchpad.net/<owner>/<repo>/ubuntu are left untouched.
#   * archive sources  -> https://archive.ubuntu.com/ubuntu
#   * security sources -> https://security.ubuntu.com/ubuntu
#   * Non-Ubuntu sources (PPA, Debian, ...) are left untouched.
#   * Never introduces a third-party apt source.
#
# Usage: reset_ubuntu_mirrors [apt_root]   (apt_root defaults to /etc/apt;
#         parametrized so tests can run against a scratch directory).
# Writes through \$SUDO so non-root runners (sudo -E) can actually modify
# /etc/apt; without sudo the Python OSError handler used to swallow the
# failure and silently no-op.
# ---------------------------------------------------------------------------
reset_ubuntu_mirrors() {
	local apt_root="${1:-/etc/apt}"
	local script
	echo "== [apt] Normalizing Ubuntu mirrors to official HTTPS archives =="

	script=$(cat <<'PYEOF'
import os, re, sys

root = sys.argv[1]
files = []
for base, _dirs, names in os.walk(root):
    for n in names:
        if n == 'sources.list' or n.endswith('.list') or n.endswith('.sources'):
            files.append(os.path.join(base, n))
files.sort()

ARCHIVE = 'https://archive.ubuntu.com/ubuntu'
SECURITY = 'https://security.ubuntu.com/ubuntu'
failed = 0

def is_ubuntu_archive(uri):
    """True only for a real Ubuntu archive/security mirror path (a single
    path segment /ubuntu or /ubuntu-security).  Third-party paths such as
    ppa.launchpad.net/<owner>/<repo>/ubuntu (multi-segment) are left alone."""
    try:
        from urllib.parse import urlparse
        path = urlparse(uri).path.rstrip('/')
    except Exception:
        return False
    if path == '/ubuntu' or path == '/ubuntu-security':
        return True
    return path.endswith('/ubuntu') and path.count('/') <= 2

for path in files:
    try:
        data = open(path, encoding='utf-8', errors='replace').read()
    except OSError as e:
        print('WARN: cannot read %s: %s' % (path, e), file=sys.stderr)
        failed += 1
        continue
    blocks = re.split(r'(?m)^[ \t]*\n', data)
    out = []
    for block in blocks:
        suites = re.search(r'(?m)^Suites:[ \t]+(.*)$', block)
        is_sec = bool(suites and '-security' in suites.group(1))

        def repl_deb(m):
            pre, uri, suite, rest = m.group(1), m.group(2), m.group(3), m.group(4)
            if not is_ubuntu_archive(uri):
                return m.group(0)
            base = SECURITY if (is_sec or '-security' in suite or 'security' in uri) else ARCHIVE
            return pre + ' ' + base + ' ' + suite + rest

        def repl_uri(m):
            uri = m.group(3)
            if not is_ubuntu_archive(uri):
                return m.group(0)
            base = SECURITY if is_sec else ARCHIVE
            return 'URIs:' + m.group(2) + base

        block = re.sub(
            r'(?m)^(deb(?:\s*-src)?(?:\s+\[[^\]]*\])?)[ \t]+(https?://\S+?)[ \t]+(\S+)(.*)$',
            repl_deb, block)
        block = re.sub(r'(?m)^(URIs:)([ \t]+)(https?://\S+)$', repl_uri, block)
        out.append(block)
    try:
        open(path, 'w', encoding='utf-8').write(''.join(out))
    except OSError as e:
        print('WARN: cannot write %s: %s' % (path, e), file=sys.stderr)
        failed += 1

sys.exit(1 if failed else 0)
PYEOF
)
	# shellcheck disable=SC2086  # SUDO intentionally word-split ("sudo -E" / "")
	if ! $SUDO python3 -c "$script" "$apt_root"; then
		echo "WARN: mirror normalization failed; continuing with existing sources" >&2
		return 1
	fi

	if [ -d "$apt_root/lists" ]; then
		# shellcheck disable=SC2086
		$SUDO rm -rf "$apt_root/lists"/*
	fi
	return 0
}

# ---------------------------------------------------------------------------
# aptx_update — normalize mirrors first, then apt-get update with exactly one
# fallback to the official archives. Never loops on the same mirror.
# ---------------------------------------------------------------------------
aptx_update() {
	reset_ubuntu_mirrors "${APT_ROOT:-/etc/apt}"
	echo "== [apt] apt-get update (attempt 1/2, official mirrors) =="
	if aptx update; then
		echo "== [apt] apt-get update OK =="
		return 0
	fi
	diagnose_apt "apt-get update (attempt 1)"
	echo "WARN: apt-get update failed; resetting mirrors and retrying once against official archives" >&2
	reset_ubuntu_mirrors "${APT_ROOT:-/etc/apt}"
	echo "== [apt] apt-get update (attempt 2/2, after mirror reset) =="
	if aptx update; then
		echo "== [apt] apt-get update OK (after mirror reset) =="
		return 0
	fi
	diagnose_apt "apt-get update (attempt 2, after mirror reset)"
	return 1
}

# ---------------------------------------------------------------------------
# diagnose_apt — print actionable diagnostics for a failing apt command.
# ---------------------------------------------------------------------------
diagnose_apt() {
	local failing_cmd="${1:-apt-get}"
	echo "===== APT DIAGNOSTIC (failed command: $failing_cmd) ====="
	echo "--- /etc/os-release (release + codename) ---"
	grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME|UBUNTU_CODENAME)=' /etc/os-release 2>/dev/null || cat /etc/os-release 2>/dev/null || true
	echo "--- apt source files (paths) ---"
	ls -la /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/*.sources 2>/dev/null || true
	echo "--- apt source entries (deb / URIs / Suites lines only) ---"
	grep -RhsE '^(deb(\s+-src)?(\s+\[[^]]*\])?\s+|URIs:|Suites:)' /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/*.sources 2>/dev/null | head -40 || true
	echo "--- mirror DNS resolution ---"
	for h in archive.ubuntu.com security.ubuntu.com; do
		if getent hosts "$h" >/dev/null 2>&1; then
			echo "$h -> $(getent hosts "$h" | awk '{print $1}' | paste -sd, -)"
		else
			echo "$h: DNS FAILED"
		fi
	done
	echo "--- dpkg/apt lock state ---"
	ls -la /var/lib/dpkg/lock* /var/lib/apt/lists/lock 2>/dev/null || echo "no lock files"
	fuser -v /var/lib/dpkg/lock 2>&1 | head -5 || true
	echo "--- running apt/dpkg processes ---"
	ps -eo pid,etime,comm,args 2>/dev/null | grep -E '[a]pt|[d]pkg' | head -20 || echo "none"
	echo "===== END APT DIAGNOSTIC ====="
}
