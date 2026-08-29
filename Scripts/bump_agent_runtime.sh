#!/bin/bash
# SPDX-License-Identifier: MIT
# Resolve the newest app-layer agent runtime releases, apply them to the locked
# manifest, and prove the result still installs for the firmware's target CPUs.
#
# Policy owner: docs/agent-runtime-version-policy.md
#   App layer (this script): opencode, pi, hermes, their extensions, pnpm and
#     Multica - allowed to follow upstream latest.
#   Runtime base (never touched here): Node.js, uv, the offline CPython mirror,
#     the OpenWrt source commit and the kernel. Those stay exact-pinned.
#
# Modes:
#   plan    print current vs latest, change nothing
#   apply   rewrite the manifest, lock and Multica pin, then run every gate
#
# apply never rolls anything back: on a failed gate it exits non-zero and leaves
# the edits in place, so the caller decides what to do with them.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST_DIR="$ROOT_DIR/Scripts/node-agent-runtime"
PACKAGE_JSON="$MANIFEST_DIR/package.json"
PACKAGE_LOCK="$MANIFEST_DIR/package-lock.json"
MULTICA_SCRIPT="$ROOT_DIR/Scripts/fetch_multica_runtime.sh"
UV_SCRIPT="$ROOT_DIR/Scripts/fetch_uv_runtime.sh"
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

manifest_packages() {
	node -e 'console.log(Object.keys(require(process.argv[1]).dependencies).join("\n"))' \
		"$PACKAGE_JSON"
}

manifest_version() {
	node -e '
		const deps = require(process.argv[1]).dependencies;
		const value = deps[process.argv[2]];
		if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(value || "")) process.exit(3);
		process.stdout.write(value);
	' "$PACKAGE_JSON" "$1" 2>/dev/null || return 1
}

set_manifest_version() {
	node -e '
		const fs = require("node:fs");
		const [path, name, version] = process.argv.slice(1);
		const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
		if (!(name in pkg.dependencies)) process.exit(4);
		pkg.dependencies[name] = version;
		fs.writeFileSync(path, `${JSON.stringify(pkg, null, 2)}\n`);
	' "$PACKAGE_JSON" "$1" "$2"
}

latest_npm_version() {
	local name="$1"
	local version

	version="$(npm view "$name" version 2>/dev/null | tail -n1 | tr -d '[:space:]')"
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		printf 'ERROR: [agent-bump] no usable latest for %s\n' "$name" >&2
		return 1
	}
	printf '%s\n' "$version"
}

multica_current_version() {
	sed -n 's/^MULTICA_VERSION="${MULTICA_VERSION:-\([^"]*\)}"$/\1/p' "$MULTICA_SCRIPT"
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
	local name current latest lines=""

	while IFS= read -r name; do
		[ -n "$name" ] || continue
		current="$(manifest_version "$name")" ||
			die "$name is not pinned to an exact version in $PACKAGE_JSON"
		latest="$(latest_npm_version "$name")" ||
			die "refusing to continue with an unresolved latest for $name"
		[ "$current" = "$latest" ] ||
			lines="${lines}${name}	${current}	${latest}
"
	done < <(manifest_packages)

	current="$(multica_current_version)"
	[ -n "$current" ] || die "unable to read MULTICA_VERSION from $MULTICA_SCRIPT"
	latest="$(multica_latest_version)" || die "unable to resolve the latest Multica release"
	[ "$current" = "$latest" ] ||
		lines="${lines}multica-cli	${current}	${latest}
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
		set_manifest_version "$name" "$latest"
		[ "$(manifest_version "$name")" = "$latest" ] ||
			die "failed to record ${name}@${latest} in $PACKAGE_JSON"
		log_info "${name} ${current} -> ${latest}"
	done <<<"$plan"

	log_info "Re-resolving the locked agent runtime..."
	npm install --package-lock-only --no-audit --no-fund --silent \
		--prefix "$MANIFEST_DIR" >/dev/null
	[ -s "$PACKAGE_LOCK" ] || die "$PACKAGE_LOCK is empty after re-resolution"
}

python_series_mirror() {
	sed -n 's/^PYTHON_SERIES=(\(.*\))$/\1/p' "$UV_SCRIPT"
}

# The same cross-target install WRT-CORE performs. A lock that cannot resolve the
# musl platform packages for a firmware CPU must never reach main.
verify_target_cpu() {
	local cpu="$1"
	local work_dir hermes_python mirrored

	work_dir="$(new_work_dir)"
	cp "$PACKAGE_JSON" "$PACKAGE_LOCK" "$work_dir/"

	npm_config_arch="$cpu" npm_config_platform=linux npm_config_libc=musl \
		npm ci --prefix "$work_dir" --omit=dev --no-audit --no-fund \
			--ignore-scripts --os=linux --cpu="$cpu" --libc=musl --silent \
			>"$work_dir/npm-ci.log" 2>&1 || {
			tail -n 30 "$work_dir/npm-ci.log" >&2 || true
			die "npm ci could not install the re-resolved lock for linux-${cpu}-musl"
		}

	[ -d "$work_dir/node_modules/opencode-linux-${cpu}-musl" ] ||
		die "linux-${cpu}-musl install is missing the matching opencode platform package"

	hermes_python="$(sed -n 's/^[[:space:]]*"pythonVersion": *"\([^"]*\)".*/\1/p' \
		"$work_dir/node_modules/hermes-agent/package.json" | head -n1)"
	[[ "$hermes_python" =~ ^[0-9]+\.[0-9]+$ ]] ||
		die "unable to read hermes-agent's managed pythonVersion for linux-${cpu}-musl"
	mirrored=" $(python_series_mirror) "
	case "$mirrored" in
		*" $hermes_python "*)
			log_info "Verified linux-${cpu}-musl install (hermes managed Python $hermes_python)."
			;;
		*)
			die "hermes-agent needs managed Python $hermes_python but $(basename "$UV_SCRIPT") mirrors:$(python_series_mirror)"
			;;
	esac
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

main() {
	local mode="${1:-plan}" plan

	case "$mode" in
		plan|apply) ;;
		*) die "unknown mode: $mode (expected plan or apply)" ;;
	esac

	require_tools
	[ -f "$PACKAGE_JSON" ] && [ -f "$PACKAGE_LOCK" ] ||
		die "locked agent runtime manifest is incomplete"
	[ -f "$MULTICA_SCRIPT" ] && [ -f "$UV_SCRIPT" ] ||
		die "runtime fetch scripts are missing"

	plan="$(resolve_plan)"
	if [ -z "$plan" ]; then
		log_info "already on the newest app-layer releases"
		return 0
	fi

	while IFS=$'\t' read -r name current latest; do
		[ -n "$name" ] || continue
		printf '  %-42s %s -> %s\n' "$name" "$current" "$latest"
	done <<<"$plan"

	case "$mode" in
		plan)
			log_info "plan mode: nothing was written"
			;;
		apply)
			apply_plan "$plan"
			verify_target_cpu arm64
			verify_target_cpu x64
			run_guard_suite
			log_info "applied and verified; ready to commit"
			;;
	esac
}

trap cleanup_work_dirs EXIT

main "$@"
