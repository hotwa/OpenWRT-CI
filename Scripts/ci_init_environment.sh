#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# ci_init_environment.sh — single entrypoint for the GitHub Actions
# "Initialization Environment" step (WRT-CORE.yml).
#
# Everything — firefox purge, Ubuntu mirror normalization, apt update,
# dependency installation and the bundled init_build_environment.sh — runs
# under ONE hard timeout applied by the caller (WRT-CORE.yml wraps this
# script in `timeout --kill-after=30 3600`). A stalled apt mirror therefore
# fails this step loudly within 60 minutes instead of wedging the runner for
# the ~1h15m GitHub previously took to declare it lost. The 60-minute bound
# is sized against the longest successful baseline run (RE-SS-01, 23 min
# Initialization Environment) plus comfortable headroom.
#
# Every apt invocation inside this script and in init_build_environment.sh
# goes through the shared aptx()/aptx_retry()/aptx_update() library, which
# bounds each command, bounds retries, and falls back to the official Ubuntu
# HTTPS archives exactly once. apt update is performed HERE exactly once;
# init_build_environment.sh deliberately does not repeat it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v sudo >/dev/null 2>&1; then
	SUDO="sudo -E"
else
	SUDO=""
fi

. "$SCRIPT_DIR/ci-apt-lib.sh"

echo "== [env] Initialization Environment start $(date -u +%Y-%m-%dT%H:%M:%SZ) =="

# 1) firefox purge — bounded and non-fatal (snapd can block headless runners;
#    the free-disk-space step already removes most large preinstalled
#    packages, and this step may simply have nothing left to purge).
echo "== [env] firefox purge (bounded, non-fatal) =="
APT_CMD_TIMEOUT=180 aptx purge firefox >/dev/null 2>&1 \
	|| echo "WARN: firefox purge skipped (timeout or already absent)" >&2

# 2) Ubuntu mirror normalization + apt update (single official-archive
#    fallback; never retries the same unreachable mirror).
aptx_update || { echo "::error::apt-get update failed (see APT DIAGNOSTIC above)"; exit 1; }

# 3) housekeeping — each bounded short and non-fatal (never allowed to eat
#    the total budget; failures only warn).
echo "== [env] apt housekeeping (autoremove / autoclean / clean, each <=120s) =="
APT_CMD_TIMEOUT=120 aptx_retry autoremove --purge || echo "WARN: apt autoremove failed (non-fatal)" >&2
APT_CMD_TIMEOUT=120 aptx_retry autoclean || echo "WARN: apt autoclean failed (non-fatal)" >&2
APT_CMD_TIMEOUT=120 aptx_retry clean || echo "WARN: apt clean failed (non-fatal)" >&2

# 4) host build prerequisites (fatal if the toolchain bits cannot install).
echo "== [env] apt install build prerequisites =="
aptx_retry install dos2unix libfuse-dev libncurses-dev libncursesw5-dev libssl-dev libelf-dev musl musl-tools qemu-user qemu-user-static \
	|| { echo "::error::apt install of build prerequisites failed"; exit 1; }

# 5) bundled ImmortalWrt environment bootstrap (needs root; runs under the
#    same 30-minute outer bound).  Normalize line endings first (idempotent;
#    the repo pins *.sh to LF via .gitattributes, this is belt-and-braces so a
#    stray CRLF can never make bash fail on the first line).
sed -i 's/\r$//' "$SCRIPT_DIR/init_build_environment.sh" 2>/dev/null || true
echo "== [env] init_build_environment.sh (root) =="
# shellcheck disable=SC2086
if ! $SUDO bash "$SCRIPT_DIR/init_build_environment.sh"; then
	echo "::error::init_build_environment.sh failed"
	exit 1
fi

echo "== [env] Initialization Environment done $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
