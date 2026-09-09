#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Disk and build-cache capacity management for WRT-CORE.
#
# Design contract (see AGENTS.md / the first CI cache batch):
#   * When free disk is above the low-water mark the recovered ccache/Go
#     caches are RETAINED. There is no unconditional `ccache -C` / rm.
#   * Below the low-water mark a fixed, ordered, bounded reclamation runs and
#     stops as soon as the target free space is reached. Before/after free
#     space and every reclaimed byte are logged with their reason.
#   * Reclamation can only touch an explicit allow-list inside the OpenWrt
#     build directory. staging_dir, build_dir, ordinary dl downloads and the
#     active Go/Node toolchains are never deleted by this script.
#   * On a self-hosted runner no host/system directory is touched.
#   * If, after every authorized step, free space is still below the
#     low-water mark the script exits distinctively instead of looping or
#     widening the cleanup into build directories.
#
# Subcommands:
#   discover-ccache --wrt-dir DIR
#   stats           --wrt-dir DIR
#   reclaim         --wrt-dir DIR [--self-hosted true|false]
#                     [--low-water-gb N] [--target-free-gb N]
#                     [--ccache-max SIZE] [--go-build-max SIZE]
#                     [--gomod-max SIZE]      (SIZE accepts K/M/G/T suffix)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/wrt_cache_lib.sh"

WRT_DIR=""
SELF_HOSTED="false"
LOW_WATER_GB=12
TARGET_FREE_GB=20
CCACHE_MAX="5G"
GO_BUILD_MAX="2G"
GOMOD_MAX="3G"
GO_BUILD_MAX_BYTES=0
GOMOD_MAX_BYTES=0

# Directories this script is allowed to shrink, relative to the OpenWrt build
# root. Anything else (staging_dir, build_dir, dl/*.tar.*, tools) is protected.
ALLOWED_SHRINK=("tmp/go-build" "dl/go-mod-cache")

log() { printf '[cache-reclaim] %s\n' "$*"; }
warn() { printf '::warning::[cache-reclaim] %s\n' "$*" >&2; }
err() { printf '::error::[cache-reclaim] %s\n' "$*" >&2; }

usage() {
	cat >&2 <<'EOF'
usage: wrt_cache_reclaim.sh <discover-ccache|stats|reclaim> [options]
  --wrt-dir DIR               OpenWrt build (TOPDIR) directory (required)
  --self-hosted true|false    skip host system cleanup on self-hosted runners
  --low-water-gb N            begin reclaiming below this free-GB mark
  --target-free-gb N          stop reclaiming once this free-GB is reached
  --ccache-max SIZE           ccache -M capacity (e.g. 5G)
  --go-build-max SIZE         tmp/go-build capacity ceiling (K/M/G)
  --gomod-max SIZE            dl/go-mod-cache capacity ceiling (K/M/G)
EOF
}

parse_args() {
	local cmd=${1:-}
	[ -n "$cmd" ] || {
		usage
		exit 2
	}
	shift || true
	while [ $# -gt 0 ]; do
		case "$1" in
		--wrt-dir) WRT_DIR=$2; shift 2 ;;
		--self-hosted) SELF_HOSTED=$2; shift 2 ;;
		--low-water-gb) LOW_WATER_GB=$2; shift 2 ;;
		--target-free-gb) TARGET_FREE_GB=$2; shift 2 ;;
		--ccache-max) CCACHE_MAX=$2; shift 2 ;;
		--go-build-max) GO_BUILD_MAX=$2; shift 2 ;;
		--gomod-max) GOMOD_MAX=$2; shift 2 ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			err "unknown argument: $1"
			usage
			exit 2
			;;
		esac
	done
	CMD="$cmd"
}

is_uint() {
	case "${1:-}" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

# Parse a K/M/G/T suffixed size into integer bytes. Echoes bytes or returns 1.
parse_size_bytes() {
	local s=${1:-} num unit mult
	case "$s" in
	'' | *[!0-9kKmMgGtT]*) return 1 ;;
	*[kKmMgGtT])
		num=${s:0:${#s}-1}
		unit=${s: -1}
		;;
	*[0-9])
		num=$s
		unit=B
		;;
	*) return 1 ;;
	esac
	is_uint "$num" || return 1
	case "$unit" in
	B) mult=1 ;;
	k | K) mult=1024 ;;
	m | M) mult=$((1024 * 1024)) ;;
	g | G) mult=$((1024 * 1024 * 1024)) ;;
	t | T) mult=$((1024 * 1024 * 1024 * 1024)) ;;
	*) return 1 ;;
	esac
	echo $((num * mult))
}

validate_config() {
	[ -n "$WRT_DIR" ] || {
		err "--wrt-dir is required"
		exit 2
	}
	is_uint "$LOW_WATER_GB" || {
		err "low-water-gb must be a non-negative integer, got '$LOW_WATER_GB'"
		exit 2
	}
	is_uint "$TARGET_FREE_GB" || {
		err "target-free-gb must be a non-negative integer, got '$TARGET_FREE_GB'"
		exit 2
	}
	GO_BUILD_MAX_BYTES=$(parse_size_bytes "$GO_BUILD_MAX") || {
		err "go-build-max must be a size like 2G/512M, got '$GO_BUILD_MAX'"
		exit 2
	}
	GOMOD_MAX_BYTES=$(parse_size_bytes "$GOMOD_MAX") || {
		err "gomod-max must be a size like 3G/512M, got '$GOMOD_MAX'"
		exit 2
	}
	if [ "$TARGET_FREE_GB" -lt "$LOW_WATER_GB" ]; then
		err "target-free-gb ($TARGET_FREE_GB) must be >= low-water-gb ($LOW_WATER_GB)"
		exit 2
	fi
	case "$CCACHE_MAX" in
	'' | *[!0-9kKmMgGtT]*)
		err "ccache-max must look like 5G/512M, got '$CCACHE_MAX'"
		exit 2
		;;
	esac
	case "$SELF_HOSTED" in
	true | false) ;;
	*)
		err "--self-hosted must be true or false, got '$SELF_HOSTED'"
		exit 2
		;;
	esac
}

# Integer free GB (floor) of the filesystem backing $1.
free_gb() {
	df -P -B1G "$1" | awk 'NR==2 {gsub(/[^0-9]/, "", $4); print $4 + 0}'
}

dir_bytes() {
	local d=${1:-}
	[ -d "$d" ] || {
		echo 0
		return
	}
	du -sb -- "$d" 2>/dev/null | awk '{print $1 + 0}'
}

human() { # bytes -> human via numfmt when available
	if command -v numfmt >/dev/null 2>&1; then
		numfmt --to=iec "${1:-0}"
	else
		echo "${1:-0}B"
	fi
}

# Locate the ccache binary OpenWrt actually compiles with. When CONFIG_CCACHE=y
# OpenWrt builds its own host ccache under staging_dir/host/bin; that one is
# authoritative. The apt ccache on PATH is only a cold-build/stat fallback.
CCACHE_BIN=""
CCACHE_KIND="none"
CCACHE_DIR_REAL=""
discover_ccache_bin() {
	CCACHE_DIR_REAL="$WRT_DIR/.ccache"
	if [ -x "$WRT_DIR/staging_dir/host/bin/ccache" ]; then
		CCACHE_BIN="$WRT_DIR/staging_dir/host/bin/ccache"
		CCACHE_KIND="openwrt-staging-host"
	elif command -v ccache >/dev/null 2>&1; then
		CCACHE_BIN="$(command -v ccache)"
		CCACHE_KIND="system-path"
	else
		CCACHE_BIN=""
		CCACHE_KIND="none"
	fi
}

print_ccache_header() {
	discover_ccache_bin
	log "ccache binary: kind=$CCACHE_KIND path=${CCACHE_BIN:-<none>} dir=$CCACHE_DIR_REAL"
	if [ -n "$CCACHE_BIN" ]; then
		log "ccache version: $("$CCACHE_BIN" --version 2>/dev/null | head -1 || echo unknown)"
	else
		log "ccache not available yet (normal on a cold build before host tools compile)"
	fi
}

ccache_stats() {
	discover_ccache_bin
	if [ -z "$CCACHE_BIN" ]; then
		log "ccache -s skipped: no ccache binary available"
		return 0
	fi
	CCACHE_DIR="$CCACHE_DIR_REAL" "$CCACHE_BIN" -s 2>/dev/null || log "ccache -s failed (non-fatal)"
}

# Apply a forward capacity ceiling. Never clears the cache.
ccache_apply_cap() {
	discover_ccache_bin
	[ -n "$CCACHE_BIN" ] || {
		log "ccache cap '$CCACHE_MAX' not applied: no ccache binary yet"
		return 0
	}
	mkdir -p "$CCACHE_DIR_REAL"
	if CCACHE_DIR="$CCACHE_DIR_REAL" "$CCACHE_BIN" -M "$CCACHE_MAX" >/dev/null 2>&1; then
		log "ccache max size set to $CCACHE_MAX via $CCACHE_KIND"
	else
		warn "ccache -M $CCACHE_MAX failed (non-fatal)"
	fi
}

# Best-effort immediate eviction (ccache v4+). Older ccache releases only trim
# on the next compile, so absence of the flag is logged, not worked around by
# a destructive `ccache -C`.
ccache_evict_oldest() {
	local days=${1:-30}
	discover_ccache_bin
	[ -n "$CCACHE_BIN" ] || return 0
	if "$CCACHE_BIN" --help 2>/dev/null | grep -q -- '--evict-older-than'; then
		log "ccache evicting entries older than ${days}d to reclaim space"
		CCACHE_DIR="$CCACHE_DIR_REAL" "$CCACHE_BIN" --evict-older-than "${days}d" 2>/dev/null || true
	else
		log "ccache has no --evict-older-than; relying on -M ceiling (no clear)"
	fi
}

# Shrink one allow-listed cache directory to a byte ceiling, deleting regular
# files oldest-first. Every removed path is re-checked to stay inside WRT_DIR.
prune_dir_to_bytes() {
	local rel=$1 cap_b=$2
	local dir="$WRT_DIR/$rel"
	wrt_cache_assert_within "$WRT_DIR" "$dir" || return 1
	local allowed=false
	local a
	for a in "${ALLOWED_SHRINK[@]}"; do
		[ "$a" = "$rel" ] && allowed=true
	done
	$allowed || {
		err "refuse to prune non-allowlisted directory: $rel"
		return 1
	}
	[ -d "$dir" ] || {
		log "$rel absent, nothing to prune"
		return 0
	}
	local before cur reclaimed=0
	before=$(dir_bytes "$dir")
	cur=$before
	if [ "$before" -le "$cap_b" ]; then
		log "$rel is $(human "$before") <= cap $(human "$cap_b"), retained"
		return 0
	fi
	log "$rel is $(human "$before") > cap $(human "$cap_b"); pruning oldest files first"
	while IFS=$'\t' read -r -d '' _mtime size path; do
		[ "$cur" -le "$cap_b" ] && break
		wrt_cache_assert_within "$WRT_DIR" "$path" || continue
		if rm -f -- "$path" 2>/dev/null; then
			cur=$((cur - size))
			reclaimed=$((reclaimed + size))
		fi
	done < <(find "$dir" -type f -printf '%T@\t%s\t%p\0' 2>/dev/null | LC_ALL=C sort -z -n)
	find "$dir" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
	log "$rel pruned $(human "$reclaimed") (now $(human "$cur"))"
}

# Host package-cache cleanup. Never runs on self-hosted runners and never
# touches the active toolchains.
host_reclaim() {
	$SELF_HOSTED && {
		log "self-hosted runner: skipping host system cleanup"
		return 0
	}
	if command -v sudo >/dev/null 2>&1; then
		sudo apt-get clean 2>/dev/null || true
		sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true
	else
		apt-get clean 2>/dev/null || true
		rm -rf /var/lib/apt/lists/* 2>/dev/null || true
	fi
	log "host apt package cache reclaimed (hosted runner only)"
}

# Reclaim feed git metadata (checked-out inside WRT_DIR). Safe and authorized.
feeds_git_reclaim() {
	local feeds="$WRT_DIR/feeds"
	[ -d "$feeds" ] || return 0
	wrt_cache_assert_within "$WRT_DIR" "$feeds" || return 1
	find "$feeds" -name ".git" -print0 2>/dev/null |
		while IFS= read -r -d '' g; do
			wrt_cache_assert_within "$WRT_DIR" "$g" || continue
			rm -rf -- "$g" 2>/dev/null || true
		done
	log "feed .git metadata reclaimed"
}

print_snapshot() {
	log "free space: $(free_gb "$WRT_DIR")G on $(df -P "$WRT_DIR" | awk 'NR==2{print $6}')"
	local d
	for d in .ccache dl/go-mod-cache tmp/go-build staging_dir/host build_dir dl; do
		[ -e "$WRT_DIR/$d" ] && log "size $d = $(du -sh -- "$WRT_DIR/$d" 2>/dev/null | awk '{print $1}')"
	done
	local tc
	for tc in "$WRT_DIR"/staging_dir/toolchain-*; do
		[ -e "$tc" ] && log "size staging_dir/$(basename "$tc") = $(du -sh -- "$tc" 2>/dev/null | awk '{print $1}')"
	done
}

cmd_discover() {
	validate_config
	print_ccache_header
}

cmd_stats() {
	validate_config
	print_snapshot
	print_ccache_header
	ccache_stats
}

cmd_reclaim() {
	validate_config
	local start_free now_free
	start_free=$(free_gb "$WRT_DIR")
	log "=== reclaim start: free=${start_free}G low-water=${LOW_WATER_GB}G target=${TARGET_FREE_GB}G self-hosted=$SELF_HOSTED ==="
	print_snapshot

	# Forward-looking ccache ceiling is always applied (does not delete data).
	ccache_apply_cap

	if [ "$start_free" -ge "$LOW_WATER_GB" ]; then
		log "disk sufficient (${start_free}G >= ${LOW_WATER_GB}G); recovered ccache/Go caches retained, no reclamation"
		print_snapshot
		log "=== reclaim end: free=$(free_gb "$WRT_DIR")G (retained) ==="
		return 0
	fi

	warn "free space ${start_free}G below low-water ${LOW_WATER_GB}G; beginning ordered reclamation"

	# Step 1: host apt cache (hosted only).
	host_reclaim
	now_free=$(free_gb "$WRT_DIR")
	log "after host cleanup: free=${now_free}G"
	[ "$now_free" -ge "$TARGET_FREE_GB" ] && finish_ok "$start_free" && return

	# Step 2: feed git metadata.
	feeds_git_reclaim
	now_free=$(free_gb "$WRT_DIR")
	log "after feeds .git cleanup: free=${now_free}G"
	[ "$now_free" -ge "$TARGET_FREE_GB" ] && finish_ok "$start_free" && return

	# Step 3: ccache eviction (v4 evicts >30d old; otherwise the -M ceiling
	# trims on the next compile). Never runs a destructive `ccache -C`.
	ccache_evict_oldest 30
	now_free=$(free_gb "$WRT_DIR")
	log "after ccache evict: free=${now_free}G"
	[ "$now_free" -ge "$TARGET_FREE_GB" ] && finish_ok "$start_free" && return

	# Step 4: bounded Go caches, build cache first (purely regenerable), then
	# the module cache (re-downloadable). Ordinary dl tarballs are untouched.
	prune_dir_to_bytes tmp/go-build "$GO_BUILD_MAX_BYTES"
	now_free=$(free_gb "$WRT_DIR")
	log "after go-build prune: free=${now_free}G"
	[ "$now_free" -ge "$TARGET_FREE_GB" ] && finish_ok "$start_free" && return

	prune_dir_to_bytes dl/go-mod-cache "$GOMOD_MAX_BYTES"
	now_free=$(free_gb "$WRT_DIR")
	log "after go-mod prune: free=${now_free}G"
	if [ "$now_free" -ge "$TARGET_FREE_GB" ]; then
		finish_ok "$start_free"
		return
	fi

	# Every authorized step has run. Do NOT widen into staging/build/dl/tools.
	print_snapshot
	if [ "$now_free" -lt "$LOW_WATER_GB" ]; then
		err "after all authorized reclamation free space is ${now_free}G < low-water ${LOW_WATER_GB}G"
		err "protected and NOT deleted: staging_dir, build_dir, ordinary dl tarballs, active Go/Node toolchains"
		err "free space manually or raise the runner; refusing unbounded cleanup"
		exit 4
	fi
	# Between low-water and target: acceptable to continue, but record it.
	warn "free space ${now_free}G is above low-water but below target ${TARGET_FREE_GB}G; continuing under pressure"
	finish_ok "$start_free"
}

finish_ok() {
	local start_free=${1:-} end_free
	end_free=$(free_gb "$WRT_DIR")
	print_snapshot
	log "=== reclaim end: free ${start_free}G -> ${end_free}G (ordered stop) ==="
}

parse_args "$@"
case "$CMD" in
discover-ccache) cmd_discover ;;
stats) cmd_stats ;;
reclaim) cmd_reclaim ;;
*)
	usage
	exit 2
	;;
esac
