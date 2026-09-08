#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Shared, side-effect-free helpers for the WRT-CORE build cache.
#
# Covers four concerns that are unit-tested by tests/test_wrt_cache_*.sh:
#   1. A *stable* compatibility scope. Only fixed logical labels and file
#      CONTENT digests ever enter the hash, so an identical checkout produces
#      an identical scope regardless of its absolute workspace/RUNNER_TEMP
#      location.
#   2. Key construction: one stable compatibility prefix plus one key that is
#      unique per workflow run/attempt (the "next generation" save key).
#   3. The save policy (test builds / failures / cancellations never publish a
#      new compile-artifact cache).
#   4. Authorization of paths that a reclamation step is allowed to touch.
#
# This file is meant to be sourced. A tiny read-only CLI is exposed when it is
# executed directly so the workflow and the test-suite can call the same code.

# --- digest primitives -----------------------------------------------------

# Content-only sha256 of a single regular file. The file path is never hashed.
wrt_cache_file_digest() {
	local f=${1:-}
	[ -f "$f" ] || {
		echo "wrt-cache-lib: not a regular file: ${f:-<empty>}" >&2
		return 1
	}
	sha256sum -- "$f" | awk '{print $1}'
}

# Stable sha256 of a directory tree. Files are enumerated with repository
# relative paths (sorted), each paired with its content digest. The absolute
# parent directory never participates, so two identical trees checked out at
# different absolute locations return the same value.
wrt_cache_tree_digest() {
	local d=${1:-}
	[ -d "$d" ] || {
		echo "wrt-cache-lib: not a directory: ${d:-<empty>}" >&2
		return 1
	}
	(
		cd "$d" || exit 1
		find . -type f -print0 | LC_ALL=C sort -z |
			while IFS= read -r -d '' f; do
				h=$(sha256sum -- "$f" | awk '{print $1}') || exit 1
				printf '%s\t%s\n' "${f#./}" "$h"
			done
	) | sha256sum | awk '{print $1}'
}

# Fold an identity manifest (stdin lines: "<fixed-label>\t<content-digest>")
# into the final compatibility scope. Callers decide label order; the same
# inputs always produce the same scope and no date/run token is mixed in here.
wrt_cache_scope_from_manifest() {
	sha256sum | awk '{print $1}'
}

# --- key construction ------------------------------------------------------

# Restrict a key component to the character class GitHub cache keys accept,
# failing closed on an empty/unsafe part instead of degrading to a broad key.
wrt_cache_sanitize_part() {
	local s=${1:-}
	local clean
	clean=$(printf '%s' "$s" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
	if [ -z "$clean" ] || [ "$clean" != "$s" ]; then
		echo "wrt-cache-lib: unsafe/empty cache key component: '${s}'" >&2
		return 1
	fi
	printf '%s' "$clean"
}

# Usage: wrt_cache_build_keys <arch/device> <scope-hex> <run_id> <run_attempt>
# Emits three lines: scope, bounded restore prefix, per-run unique save key.
# The restore prefix ends in a literal "-run" boundary immediately after the
# full scope hash, so restore-keys can only match entries that share the exact
# compatibility scope (never a bare arch/device prefix).
wrt_cache_build_keys() {
	local arch=${1:-} scope=${2:-} run_id=${3:-} run_attempt=${4:-}
	local a
	a=$(wrt_cache_sanitize_part "$arch") || return 1
	# scope must be a non-empty 64-char lowercase hex sha256 digest.
	if [ ${#scope} -ne 64 ] || printf '%s' "$scope" | grep -Eq '[^0-9a-f]'; then
		echo "wrt-cache-lib: scope must be a 64-char lowercase hex digest" >&2
		return 1
	fi
	case "$run_id" in '' | *[!0-9]*) echo "wrt-cache-lib: run_id must be numeric" >&2; return 1 ;; esac
	case "$run_attempt" in '' | *[!0-9]*) echo "wrt-cache-lib: run_attempt must be numeric" >&2 ; return 1 ;; esac

	local prefix="${a}-${scope}-run"
	local save="${prefix}${run_id}-at${run_attempt}"
	printf '%s\n%s\n%s\n' "$scope" "$prefix" "$save"
}

# --- save policy ------------------------------------------------------------

# Usage: wrt_cache_save_decision <wrt_test true|false> <compile_outcome> <cancelled true|false>
# Emits "save" or "skip:<reason>". A compile-artifact cache is published only
# for a non-test build whose compile step succeeded and which was not cancelled.
wrt_cache_save_decision() {
	local is_test=${1:-false} outcome=${2:-unknown} cancelled=${3:-false}
	if [ "$cancelled" = "true" ]; then
		echo "skip:cancelled"
		return 0
	fi
	if [ "$is_test" = "true" ]; then
		echo "skip:test-build"
		return 0
	fi
	if [ "$outcome" != "success" ]; then
		echo "skip:compile-${outcome}"
		return 0
	fi
	echo "save"
}

# --- path authorization -----------------------------------------------------

# Assert that $2 resolves to $1 or a descendant of it. Used before any cache
# reclamation rm so a symlink/relative escape can never reach an unauthorized
# directory. -m lets the target not exist yet.
wrt_cache_assert_within() {
	local root=${1:-} p=${2:-} rr rp
	[ -n "$root" ] || {
		echo "wrt-cache-lib: assert-within needs a root" >&2
		return 1
	}
	rr=$(realpath -- "$root") || return 1
	rp=$(realpath -m -- "$p") || return 1
	case "$rp" in
	"$rr" | "$rr"/*) return 0 ;;
	*)
		echo "wrt-cache-lib: path escapes authorized build root: $p (root=$rr)" >&2
		return 1
		;;
	esac
}

# --- read-only CLI ----------------------------------------------------------

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
	cmd=${1:-}
	shift || true
	case "$cmd" in
	file-digest)
		wrt_cache_file_digest "$@"
		;;
	tree-digest)
		wrt_cache_tree_digest "$@"
		;;
	scope)
		wrt_cache_scope_from_manifest
		;;
	keys)
		wrt_cache_build_keys "$@"
		;;
	save-decision)
		wrt_cache_save_decision "$@"
		;;
	assert-within)
		wrt_cache_assert_within "$@"
		;;
	*)
		cat >&2 <<'USAGE'
usage: wrt_cache_lib.sh <command> [args]
  file-digest <file>
  tree-digest <dir>
  scope                      # reads label<TAB>digest manifest on stdin
  keys <arch> <scope> <run_id> <run_attempt>
  save-decision <wrt_test> <compile_outcome> <cancelled>
  assert-within <root> <path>
USAGE
		exit 2
		;;
	esac
fi
