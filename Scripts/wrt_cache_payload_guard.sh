#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build-cache payload boundary guard for WRT-CORE.
#
# actions/cache archives exactly the paths listed in its `path:` block. This
# script encodes that SAME explicit whitelist and refuses to let a cache be
# saved when those paths contain a firmware rootfs image or private material
# (keys / credentials / auth state). A private key suffix on the cache key is
# not an access-control boundary, so safety is enforced by what we archive.
#
# Whitelist (relative to the OpenWrt TOPDIR), kept conservative on purpose:
#   .ccache                     compiler cache (regenerable)
#   staging_dir/host            OpenWrt host tools
#   staging_dir/toolchain-*     cross toolchain(s)
#   dl/go-mod-cache             Go module cache (re-downloadable)
#   tmp/go-build                Go build cache (regenerable)
#
# Deliberately NOT cached this round (see the delivery report):
#   staging_dir/target-*        holds root-* staged target rootfs
#   build_dir                   per-build object/rootfs assembly
#   files                       private feature/credential overlay
#   bin                         finished firmware images
#
# Subcommand:
#   manifest --wrt-dir DIR    print whitelist sizes; exit 4 if a secret/rootfs
#                             indicator would be archived, else 0.
set -euo pipefail

WRT_DIR=""

# Keep this list identical to the actions/cache path: block in WRT-CORE.yml.
WHITELIST_GLOBS=(
	".ccache"
	"staging_dir/host"
	"staging_dir/toolchain-*"
	"dl/go-mod-cache"
	"tmp/go-build"
)

# Basename / path indicators for material that must never be cached.
SECRET_NAME_REGEX='(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa|authorized_keys|shadow|gshadow|.*\.(pem|key)|tailscaled\.state|headscale_auto_enroll|.*hskey.*)$'
# Content indicators (scanned on the leading bytes of reasonably small files).
# The first alternative intentionally stays generic ("BEGIN " + optional
# algorithm word + "PRIVATE KEY") so it matches RSA/EC/DSA/OPENSSH and the
# header-less PKCS#8 form without spelling a contiguous PEM marker in source
# (repo secret scanners forbid such contiguous literals).
SECRET_BODY_REGEX='BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY|hskey-auth-|MULTICA_TOKEN=|AWS_SECRET_ACCESS_KEY'
# Assembled rootfs / image indicators that prove target rootfs leaked in.
ROOTFS_NAME_REGEX='(^|/)(rootfs.*\.(tar|squashfs|ext4|img|bin)$|.*\.(ubi|factory\.bin|sysupgrade\.bin)$)'

CONTENT_SCAN_MAX_BYTES=$((1024 * 1024))

log() { printf '[cache-payload] %s\n' "$*"; }
err() { printf '::error::[cache-payload] %s\n' "$*" >&2; }

usage() {
	echo "usage: wrt_cache_payload_guard.sh manifest --wrt-dir DIR" >&2
}

parse_args() {
	local cmd=${1:-}
	[ "$cmd" = "manifest" ] || {
		usage
		exit 2
	}
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--wrt-dir) WRT_DIR=$2; shift 2 ;;
		*)
			err "unknown argument $1"
			usage
			exit 2
			;;
		esac
	done
	[ -n "$WRT_DIR" ] || {
		err "--wrt-dir required"
		exit 2
	}
	[ -d "$WRT_DIR" ] || {
		err "build dir does not exist: $WRT_DIR"
		exit 2
	}
}

# Expand a whitelist glob to existing directories (NUL-delimited, absolute).
existing_whitelist_paths() {
	local glob matches
	for glob in "${WHITELIST_GLOBS[@]}"; do
		# shellcheck disable=SC2086
		find "$WRT_DIR" -maxdepth "$(awk -F/ '{print NF}' <<<"$glob")" -path "$WRT_DIR/$glob" -print0 2>/dev/null || true
	done
}

scan_path() {
	local root=$1
	SCAN_OFFENDERS=0
	while IFS= read -r -d '' f; do
		local rel=${f#"$WRT_DIR/"}
		# Name-based check (applies to every file).
		if printf '%s' "$rel" | grep -Eiq "$SECRET_NAME_REGEX"; then
			err "secret-like filename in cache whitelist: $rel"
			SCAN_OFFENDERS=$((SCAN_OFFENDERS + 1))
			continue
		fi
		if printf '%s' "$rel" | grep -Eiq "$ROOTFS_NAME_REGEX"; then
			err "assembled rootfs/firmware image in cache whitelist: $rel"
			SCAN_OFFENDERS=$((SCAN_OFFENDERS + 1))
			continue
		fi
		# Content check bounded to small-ish files to stay cheap on binaries.
		local sz
		sz=$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)
		if [ "$sz" -le "$CONTENT_SCAN_MAX_BYTES" ] && [ "$sz" -gt 0 ]; then
			if head -c "$CONTENT_SCAN_MAX_BYTES" -- "$f" 2>/dev/null | grep -aEq "$SECRET_BODY_REGEX"; then
				err "credential/key content in cache whitelist file: $rel"
				SCAN_OFFENDERS=$((SCAN_OFFENDERS + 1))
			fi
		fi
	done < <(find "$root" -type f -print0 2>/dev/null)
	[ "$SCAN_OFFENDERS" -eq 0 ]
}

# Wrapper usable under set -e; sets SCAN_OFFENDERS and returns 0 when clean.
scan_ok() {
	SCAN_OFFENDERS=0
	scan_path "$1"
}

cmd_manifest() {
	log "cache payload whitelist (relative to $WRT_DIR):"
	for g in "${WHITELIST_GLOBS[@]}"; do
		log "  + $g"
	done
	log "excluded by policy: staging_dir/target-* (staged rootfs), build_dir, files, bin"

	local total_offenders=0 seen=0
	PAYLOAD_TMP_LIST=$(mktemp)
	trap 'rm -f "${PAYLOAD_TMP_LIST:-}"' EXIT
	existing_whitelist_paths >"$PAYLOAD_TMP_LIST"

	while IFS= read -r -d '' p; do
		seen=1
		local sz
		sz=$(du -sh -- "$p" 2>/dev/null | awk '{print $1}')
		log "candidate: ${p#"$WRT_DIR/"} (${sz:-?})"
		if ! scan_ok "$p"; then
			total_offenders=$((total_offenders + SCAN_OFFENDERS))
		fi
	done <"$PAYLOAD_TMP_LIST"

	[ "$seen" -eq 1 ] || log "no whitelist path exists yet (cold build) - nothing to archive"

	if [ "$total_offenders" -gt 0 ]; then
		err "refusing cache save: $total_offenders secret/rootfs indicator(s) inside the whitelist"
		exit 4
	fi
	log "payload boundary check passed; no secret/rootfs indicator in whitelist"
}

parse_args "$@"
cmd_manifest
