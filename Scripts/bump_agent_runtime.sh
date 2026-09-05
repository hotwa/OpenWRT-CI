#!/bin/bash
# SPDX-License-Identifier: MIT
# Resolve the newest source-controlled app-layer inputs.  Pi and its extension
# catalog deliberately remain latest-at-build: fetch_node_runtime.sh resolves,
# aligns and imports them in the candidate generation itself.
#
# Policy owner: docs/agent-runtime-version-policy.md
#   App layer: Pi, CommandCode and extensions resolve latest during every
#     generation build; this script updates Multica and the reviewed vendored
#     plan extension.
#   Runtime base (never touched here): Node.js, the OpenWrt source commit and
#     the kernel. Those stay exact-pinned.
#
# Modes:
#   plan    print current vs latest, change nothing
#   apply            rewrite source-controlled inputs, then run repository guards
#   advance-release  advance only the immutable signed-generation sequence
#
# apply never rolls anything back: on a failed gate it exits non-zero and leaves
# the edits in place, so the caller decides what to do with them.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST_DIR="$ROOT_DIR/Scripts/node-agent-runtime"
PACKAGE_JSON="$MANIFEST_DIR/package.json"
RUNTIME_RELEASE_FILE="${AGENT_RUNTIME_RELEASE_FILE:-$MANIFEST_DIR/runtime-release}"
PI_PLAN_VENDOR_SCRIPT="$ROOT_DIR/Scripts/refresh_pi_plan_mode_vendor.sh"
PI_PLAN_PROVENANCE="$MANIFEST_DIR/vendor/pi-plan-mode/provenance.json"
MULTICA_SCRIPT="$ROOT_DIR/Scripts/fetch_multica_runtime.sh"
GUARD_DIR="$ROOT_DIR/tests"
GITHUB_API="https://api.github.com/repos"
CLEANUP_DIRS=()

log_info() {
	printf 'INFO: [agent-bump] %s\n' "$*"
}

die() {
	printf 'ERROR: [agent-bump] %s\n' "$*" >&2
	exit 1
}

cleanup_work_dirs() {
	[ "${#CLEANUP_DIRS[@]}" -eq 0 ] || rm -rf -- "${CLEANUP_DIRS[@]}"
}

require_tools() {
	command -v node >/dev/null 2>&1 || die "node is required"
	command -v npm >/dev/null 2>&1 || die "npm is required"
	command -v curl >/dev/null 2>&1 || die "curl is required"
}

new_work_dir() {
	local dir

	dir="$(mktemp -d)"
	CLEANUP_DIRS+=("$dir")
	printf '%s\n' "$dir"
}

github_api() {
	local url="$1"
	local -a auth=()

	[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL --retry 4 --retry-delay 5 --max-time 60 \
		-H "Accept: application/vnd.github+json" "${auth[@]}" "$url"
}

multica_current_version() {
	sed -n 's/^MULTICA_VERSION="${MULTICA_VERSION:-\([^"]*\)}"$/\1/p' "$MULTICA_SCRIPT"
}

pi_plan_vendor_current() {
	node -e '
		const metadata = require(process.argv[1]);
		if (!/^\d+\.\d+\.\d+$/.test(metadata.version || "") ||
			!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(metadata.npm?.integrity || "")) process.exit(3);
		process.stdout.write(`${metadata.version}\t${metadata.npm.integrity}`);
	' "$PI_PLAN_PROVENANCE" 2>/dev/null || return 1
}

pi_plan_vendor_latest() {
	# Asking npm for dist.integrity produces a flattened JSON key named
	# "dist.integrity", while the parser below intentionally validates the
	# nested dist object. Request dist so both sides use the same shape.
	npm view pi-plan-mode version dist --json |
		node -e '
			let input = "";
			process.stdin.on("data", (chunk) => { input += chunk; });
			process.stdin.on("end", () => {
				const metadata = JSON.parse(input);
				if (!/^\d+\.\d+\.\d+$/.test(metadata.version || "") ||
					!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(metadata.dist?.integrity || "")) process.exit(3);
				process.stdout.write(`${metadata.version}\t${metadata.dist.integrity}`);
			});
		' || return 1
}

multica_latest_version() {
	local tag

	tag="$(github_api "$GITHUB_API/multica-ai/multica/releases/latest" |
		node -e '
			let data = "";
			process.stdin.on("data", chunk => data += chunk);
			process.stdin.on("end", () => process.stdout.write(JSON.parse(data).tag_name || ""));
		')"
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		printf 'ERROR: [agent-bump] unexpected latest Multica tag: %s\n' "$tag" >&2
		return 1
	}
	printf '%s\n' "${tag#v}"
}

set_multica_version() {
	sed -i "s/^MULTICA_VERSION=\"\${MULTICA_VERSION:-[^\"]*}\"$/MULTICA_VERSION=\"\${MULTICA_VERSION:-$1}\"/" \
		"$MULTICA_SCRIPT"
	[ "$(multica_current_version)" = "$1" ] ||
		die "failed to record Multica $1 in $MULTICA_SCRIPT"
}

# Emits "name<TAB>current<TAB>latest" for everything that has moved.
resolve_plan() {
	local current latest lines="" vendor_current vendor_latest vendor_current_version vendor_current_integrity vendor_latest_version vendor_latest_integrity

	current="$(multica_current_version)"
	[ -n "$current" ] || die "unable to read MULTICA_VERSION from $MULTICA_SCRIPT"
	latest="$(multica_latest_version)" || die "unable to resolve the latest Multica release"
	[ "$current" = "$latest" ] ||
		lines="${lines}multica-cli	${current}	${latest}
"

	vendor_current="$(pi_plan_vendor_current)" || die "unable to read vendored pi-plan-mode provenance"
	vendor_latest="$(pi_plan_vendor_latest)" || die "unable to resolve latest pi-plan-mode metadata"
	IFS=$'\t' read -r vendor_current_version vendor_current_integrity <<<"$vendor_current"
	IFS=$'\t' read -r vendor_latest_version vendor_latest_integrity <<<"$vendor_latest"
	[ "$vendor_current_version" = "$vendor_latest_version" ] && \
		[ "$vendor_current_integrity" = "$vendor_latest_integrity" ] ||
		lines="${lines}pi-plan-mode-vendor	${vendor_current_version}	${vendor_latest_version}
"

	printf '%s' "$lines"
}

apply_plan() {
	local plan="$1" name current latest

	while IFS=$'\t' read -r name current latest; do
		[ -n "$name" ] || continue
		if [ "$name" = "multica-cli" ]; then
			set_multica_version "$latest"
			log_info "Multica ${current} -> ${latest}"
			continue
		fi
		if [ "$name" = "pi-plan-mode-vendor" ]; then
			bash "$PI_PLAN_VENDOR_SCRIPT" apply "$latest"
			log_info "vendored pi-plan-mode ${current} -> ${latest}"
			continue
		fi
		die "unexpected source-controlled runtime component: $name"
	done <<<"$plan"
}

run_guard_suite() {
	local log_dir test_file failures=0

	[ -d "$GUARD_DIR" ] || die "missing $GUARD_DIR"
	log_dir="$(new_work_dir)"
	for test_file in "$GUARD_DIR"/test_*.sh; do
		[ -f "$test_file" ] || continue
		if bash "$test_file" </dev/null >"$log_dir/$(basename "$test_file").log" 2>&1; then
			continue
		fi
		failures=$((failures + 1))
		printf 'ERROR: [agent-bump] %s failed:\n' "$test_file" >&2
		tail -n 20 "$log_dir/$(basename "$test_file").log" >&2 || true
	done
	[ "$failures" -eq 0 ] || die "$failures repository guard test(s) failed"
	log_info "Repository guard suite passed."
}

advance_runtime_release() {
	local current next
	current="$(sed -n '1p' "$RUNTIME_RELEASE_FILE" 2>/dev/null || true)"
	[[ "$current" =~ ^[1-9][0-9]*$ ]] || die "invalid runtime release counter in $RUNTIME_RELEASE_FILE"
	# This counter is a release sequence, not a timestamp.  In particular it
	# must not be derived from a router's wall clock: an old firmware clock must
	# never make a valid signed update appear to move backwards.
	[ "$current" -lt 9007199254740991 ] || die "runtime release counter exceeds JSON safe integer range"
	next=$((current + 1))
	printf '%s\n' "$next" >"$RUNTIME_RELEASE_FILE"
	log_info "Advanced runtime release $current -> $next."
}

main() {
	local mode="${1:-plan}" plan

	case "$mode" in
		plan|apply|advance-release) ;;
		*) die "unknown mode: $mode (expected plan, apply or advance-release)" ;;
	esac

	require_tools
	[ -f "$PACKAGE_JSON" ] || die "latest-at-build agent runtime catalog is incomplete"
	if [ "$mode" = "advance-release" ]; then
		advance_runtime_release
		exit 0
	fi
	[ -f "$PI_PLAN_VENDOR_SCRIPT" ] && [ -f "$PI_PLAN_PROVENANCE" ] ||
		die "vendored pi-plan-mode refresh chain is incomplete"
	[ -f "$MULTICA_SCRIPT" ] || die "Multica runtime fetch script is missing"

	plan="$(resolve_plan)"
	# Validate the upstream archive and the narrowly reviewed PR #9 scope patch
	# even when its version has not moved; registry substitutions fail closed.
	bash "$PI_PLAN_VENDOR_SCRIPT" plan
	[ -n "$plan" ] || log_info "Pi/extensions are latest-at-build; no source-controlled component changed"

	while IFS=$'\t' read -r name current latest; do
		[ -n "$name" ] || continue
		printf '  %-42s %s -> %s\n' "$name" "$current" "$latest"
	done <<<"$plan"

	case "$mode" in
		plan)
			log_info "plan mode: nothing was written"
			;;
		apply)
			[ -z "$plan" ] || apply_plan "$plan"
			run_guard_suite
			log_info "source-controlled inputs verified; candidate generation will resolve Pi/plugins"
			;;
	esac
}

trap cleanup_work_dirs EXIT

main "$@"
