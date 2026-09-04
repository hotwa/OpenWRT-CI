#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Refresh the reviewed, firmware-vendored copy of pi-plan-mode.  npm's published
# package still uses the legacy Pi scope; qmx/pi-plan-mode#9 is the deliberately
# tiny source migration we apply after verifying the upstream archive verbatim.
# Anything other than that scope migration is a hard failure.

set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RUNTIME_DIR="$ROOT_DIR/Scripts/node-agent-runtime"
VENDOR_DIR="$RUNTIME_DIR/vendor/pi-plan-mode"
LICENSE_TEMPLATE="$VENDOR_DIR/LICENSE"
UPSTREAM_REPOSITORY="qmx/pi-plan-mode"
UPSTREAM_PULL_REQUEST=9
EXPECTED_SCOPE_PR_HEAD="8bf61ebb34647c1d22848fb951a2234965693cef"
NPM_PACKAGE="pi-plan-mode"
NPM_REGISTRY="https://registry.npmjs.org"
GITHUB_API="https://api.github.com/repos"
CLEANUP_DIRS=()

log_info() {
	printf 'INFO: [pi-plan-mode-vendor] %s\n' "$*"
}

die() {
	printf 'ERROR: [pi-plan-mode-vendor] %s\n' "$*" >&2
	exit 1
}

cleanup_work_dirs() {
	[ "${#CLEANUP_DIRS[@]}" -eq 0 ] || rm -rf -- "${CLEANUP_DIRS[@]}"
}

new_work_dir() {
	local dir
	dir="$(mktemp -d)"
	CLEANUP_DIRS+=("$dir")
	printf '%s\n' "$dir"
}

require_tools() {
	local tool
	for tool in curl node npm tar sha256sum mktemp; do
		command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
	done
	[ -f "$LICENSE_TEMPLATE" ] || die "missing vendored MIT LICENSE template"
}

github_api() {
	local url="$1"
	local -a auth=()
	[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL --retry 4 --retry-delay 5 --max-time 60 \
		-H "Accept: application/vnd.github+json" "${auth[@]}" "$url"
}

source_sha256() {
	sha256sum "$1" | awk '{print $1}'
}

verify_sri() {
	local archive="$1" integrity="$2"
	node - "$archive" "$integrity" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const [archive, integrity] = process.argv.slice(2);
const match = /^(sha512)-([A-Za-z0-9+/]+={0,2})$/.exec(integrity || "");
if (!match) process.exit(2);
const actual = crypto.createHash(match[1]).update(fs.readFileSync(archive)).digest("base64");
if (actual !== match[2]) process.exit(3);
NODE
}

read_npm_release() {
	local version="$1"
	npm view "${NPM_PACKAGE}@${version}" version gitHead dist --json |
		node -e '
let data = "";
process.stdin.on("data", (chunk) => { data += chunk; });
process.stdin.on("end", () => {
  const meta = JSON.parse(data);
  const version = meta.version;
  const gitHead = meta.gitHead;
  const dist = meta.dist || {};
  if (!/^\d+\.\d+\.\d+$/.test(version || "") || !/^[0-9a-f]{40}$/.test(gitHead || "")) process.exit(2);
  if (typeof dist.tarball !== "string" || !dist.tarball.startsWith("https://registry.npmjs.org/")) process.exit(3);
  if (!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(dist.integrity || "")) process.exit(4);
  process.stdout.write(JSON.stringify({ version, gitHead, tarball: dist.tarball, integrity: dist.integrity }));
});'
}

read_scope_pull_request() {
	github_api "$GITHUB_API/$UPSTREAM_REPOSITORY/pulls/$UPSTREAM_PULL_REQUEST" |
		EXPECTED_SCOPE_PR_HEAD="$EXPECTED_SCOPE_PR_HEAD" node -e '
let data = "";
process.stdin.on("data", (chunk) => { data += chunk; });
process.stdin.on("end", () => {
  const pr = JSON.parse(data);
  if (pr.number !== 9 || pr.base?.repo?.full_name !== "qmx/pi-plan-mode") process.exit(2);
  if (!/^[0-9a-f]{40}$/.test(pr.base?.sha || "") || !/^[0-9a-f]{40}$/.test(pr.head?.sha || "")) process.exit(3);
  if (pr.head.sha !== process.env.EXPECTED_SCOPE_PR_HEAD) process.exit(4);
  process.stdout.write(JSON.stringify({ base: pr.base.sha, head: pr.head.sha, url: pr.html_url }));
});'
}

verify_archive_layout() {
	local archive="$1"
	local actual expected
	actual="$(tar -tzf "$archive" | LC_ALL=C sort)"
	expected=$'package/README.md\npackage/package.json\npackage/plan-mode.ts'
	[ "$actual" = "$expected" ] || die "unexpected archive layout; expected only package.json, README.md and plan-mode.ts"
}

apply_scope_migration() {
	local source_dir="$1" stage_dir="$2" version="$3"
	cp "$source_dir/README.md" "$stage_dir/README.md"
	cp "$source_dir/package.json" "$stage_dir/package.json"
	cp "$source_dir/plan-mode.ts" "$stage_dir/plan-mode.ts"
	cp "$LICENSE_TEMPLATE" "$stage_dir/LICENSE"

	node - "$stage_dir/package.json" "$stage_dir/plan-mode.ts" "$version" <<'NODE'
const fs = require("node:fs");
const [packagePath, extensionPath, expectedVersion] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(packagePath, "utf8"));
if (pkg.name !== "pi-plan-mode" || pkg.version !== expectedVersion || pkg.license !== "MIT") process.exit(2);
if (pkg.repository?.url !== "https://github.com/qmx/pi-plan-mode") process.exit(3);
if (JSON.stringify(pkg.files) !== JSON.stringify(["plan-mode.ts", "README.md"])) process.exit(4);
if (!Array.isArray(pkg.pi?.extensions) || pkg.pi.extensions.length !== 1 || pkg.pi.extensions[0] !== "./plan-mode.ts") process.exit(5);

if (pkg.peerDependencies?.["@mariozechner/pi-ai"] === "*") {
  delete pkg.peerDependencies["@mariozechner/pi-ai"];
  pkg.peerDependencies["@earendil-works/pi-ai"] = "*";
} else if (pkg.peerDependencies?.["@earendil-works/pi-ai"] !== "*") process.exit(7);
if (pkg.peerDependencies?.["@mariozechner/pi-coding-agent"] === "^0.63.0") {
  delete pkg.peerDependencies["@mariozechner/pi-coding-agent"];
  pkg.peerDependencies["@earendil-works/pi-coding-agent"] = ">=0.63.0 <1.0.0";
} else if (pkg.peerDependencies?.["@earendil-works/pi-coding-agent"] !== ">=0.63.0 <1.0.0") process.exit(8);
if (pkg.devDependencies?.["@mariozechner/pi-coding-agent"] === "^0.63.0") {
  delete pkg.devDependencies["@mariozechner/pi-coding-agent"];
  pkg.devDependencies["@earendil-works/pi-coding-agent"] = "^0.75.0";
} else if (pkg.devDependencies?.["@earendil-works/pi-coding-agent"] !== "^0.75.0") process.exit(9);
if (JSON.stringify(pkg).includes("@mariozechner/")) process.exit(10);

let extension = fs.readFileSync(extensionPath, "utf8");
function replaceImport(oldText, newText) {
  if (extension.includes(oldText)) extension = extension.replace(oldText, newText);
  else if (!extension.includes(newText)) process.exit(11);
}
replaceImport('from "@mariozechner/pi-coding-agent"', 'from "@earendil-works/pi-coding-agent"');
replaceImport('from "@mariozechner/pi-ai"', 'from "@earendil-works/pi-ai"');
if (extension.includes("@mariozechner/")) process.exit(12);

// OpenWrt devices run untrusted/remote agent work. Keep the upstream command
// but make every new session start in read-only plan mode; a local human must
// explicitly use /plan to enable writes for that session.
const upstreamDefault = 'let planModeEnabled = false;';
const localDefault = 'let planModeEnabled = true;';
if (extension.includes(upstreamDefault)) extension = extension.replace(upstreamDefault, localDefault);
else if (!extension.includes(localDefault)) process.exit(13);

fs.writeFileSync(packagePath, `${JSON.stringify(pkg, null, 2)}\n`);
fs.writeFileSync(extensionPath, extension);
NODE
}

write_provenance() {
	local stage_dir="$1" release_json="$2" pr_json="$3"
	local package_hash readme_hash extension_hash license_hash archive_hash
	package_hash="$(source_sha256 "$stage_dir/package.json")"
	readme_hash="$(source_sha256 "$stage_dir/README.md")"
	extension_hash="$(source_sha256 "$stage_dir/plan-mode.ts")"
	license_hash="$(source_sha256 "$stage_dir/LICENSE")"
	archive_hash="$(source_sha256 "$4")"

	node - "$stage_dir/provenance.json" "$release_json" "$pr_json" "$package_hash" "$readme_hash" "$extension_hash" "$license_hash" "$archive_hash" <<'NODE'
const fs = require("node:fs");
const [path, releaseRaw, prRaw, packageHash, readmeHash, extensionHash, licenseHash, archiveHash] = process.argv.slice(2);
const release = JSON.parse(releaseRaw);
const pr = JSON.parse(prRaw);
const provenance = {
  schema_version: 1,
  version: release.version,
  license: {
    spdx: "MIT",
    notice: "Upstream package metadata declares MIT. The npm archive contains no LICENSE file; this vendored copy preserves the canonical MIT text.",
    sha256: licenseHash,
  },
  upstream: {
    repository: "qmx/pi-plan-mode",
    release_commit: release.gitHead,
    commit: pr.head,
    pull_request: 9,
    pull_url: pr.url,
    scope_migration: "PR #9 only replaces @mariozechner/pi-coding-agent and @mariozechner/pi-ai with @earendil-works equivalents, and widens the Pi peer range as reviewed in that PR.",
    local_policy: "OpenWrt firmware defaults each new Pi session to read-only plan mode; a human must explicitly use /plan to enable writes for that session.",
  },
  npm: { tarball: release.tarball, integrity: release.integrity, sha256: archiveHash },
  source_layout: ["package.json", "README.md", "plan-mode.ts"],
  source_sha256: { "package.json": packageHash, "README.md": readmeHash, "plan-mode.ts": extensionHash },
};
fs.writeFileSync(path, `${JSON.stringify(provenance, null, 2)}\n`);
NODE
}

refresh_vendor() {
	local version="$1" work_dir release_json pr_json tarball integrity source_dir stage_dir backup_dir
	work_dir="$(new_work_dir)"
	release_json="$(read_npm_release "$version")" || die "unable to resolve npm metadata for ${NPM_PACKAGE}@${version}"
	pr_json="$(read_scope_pull_request)" || die "unable to verify $UPSTREAM_REPOSITORY pull request #$UPSTREAM_PULL_REQUEST"
	tarball="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).tarball)' "$release_json")"
	integrity="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).integrity)' "$release_json")"

	curl -fsSL --retry 4 --retry-delay 5 --max-time 120 "$tarball" -o "$work_dir/source.tgz" ||
		die "could not download ${NPM_PACKAGE}@${version}"
	verify_sri "$work_dir/source.tgz" "$integrity" || die "npm SRI verification failed"
	verify_archive_layout "$work_dir/source.tgz"

	mkdir -p "$work_dir/source" "$work_dir/stage"
	tar -xzf "$work_dir/source.tgz" -C "$work_dir/source" --no-same-owner --no-same-permissions
	source_dir="$work_dir/source/package"
	stage_dir="$work_dir/stage/pi-plan-mode"
	mkdir -p "$stage_dir"
	apply_scope_migration "$source_dir" "$stage_dir" "$version" ||
		die "scope migration differs from qmx/pi-plan-mode pull request #9"
	write_provenance "$stage_dir" "$release_json" "$pr_json" "$work_dir/source.tgz"

	if [ "$MODE" = plan ]; then
		log_info "validated ${NPM_PACKAGE}@${version}; vendored source would be refreshed"
		return 0
	fi

	backup_dir="$work_dir/previous"
	[ -d "$VENDOR_DIR" ] && mv "$VENDOR_DIR" "$backup_dir"
	if mv "$stage_dir" "$VENDOR_DIR"; then
		log_info "refreshed vendored ${NPM_PACKAGE}@${version}"
	else
		[ ! -d "$backup_dir" ] || mv "$backup_dir" "$VENDOR_DIR"
		die "could not atomically replace vendored source"
	fi
}

main() {
	local requested_version="${2:-}" latest
	MODE="${1:-plan}"
	case "$MODE" in
		plan|apply) ;;
		*) die "unknown mode: $MODE (expected plan or apply)" ;;
	esac
	require_tools
	if [ -n "$requested_version" ]; then
		[[ "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be exact semver"
		refresh_vendor "$requested_version"
		return
	fi
	latest="$(npm view "$NPM_PACKAGE" version 2>/dev/null | tail -n1 | tr -d '[:space:]')"
	[[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no usable latest for $NPM_PACKAGE"
	refresh_vendor "$latest"
}

trap cleanup_work_dirs EXIT

main "$@"
