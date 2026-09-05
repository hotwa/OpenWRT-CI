#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/Scripts/node-agent-runtime"
VENDOR_DIR="$RUNTIME_DIR/vendor/pi-plan-mode"
PACKAGE_JSON="$RUNTIME_DIR/package.json"
PROVENANCE="$VENDOR_DIR/provenance.json"
REFRESH_SCRIPT="$ROOT_DIR/Scripts/refresh_pi_plan_mode_vendor.sh"
MIGRATION="$ROOT_DIR/files/etc/uci-defaults/98-pi-plan-mode-vendor-migration"
RECONCILE="$ROOT_DIR/files/usr/sbin/pi-plan-mode-reconcile"
BUMP_SCRIPT="$ROOT_DIR/Scripts/bump_agent_runtime.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

fail() {
  echo "pi-plan-mode vendor guard: $*" >&2
  exit 1
}

for path in "$PACKAGE_JSON" "$VENDOR_DIR/package.json" \
  "$VENDOR_DIR/plan-mode.ts" "$VENDOR_DIR/README.md" "$VENDOR_DIR/LICENSE" \
  "$PROVENANCE" "$REFRESH_SCRIPT" "$MIGRATION" "$RECONCILE" "$BUMP_SCRIPT"; do
  [ -f "$path" ] || fail "missing $path"
done

if grep -Eq '"pi-plan-mode"[[:space:]]*:' "$PACKAGE_JSON"; then
  fail "pi-plan-mode must not remain an npm root dependency"
fi

node - "$PACKAGE_JSON" <<'NODE' || fail "source Pi catalog must remain latest-at-build"
const manifest = require(process.argv[2]);
if (Object.values(manifest.dependencies || {}).some(value => value !== 'latest')) process.exit(1);
NODE
[ ! -e "$RUNTIME_DIR/package-lock.json" ] || fail "source lockfile would freeze Pi/plugin resolution"
bash -n "$BUMP_SCRIPT" || fail "agent bump script does not parse"

node - "$VENDOR_DIR/package.json" "$PROVENANCE" <<'NODE' || fail "vendor metadata is invalid"
const fs = require("node:fs");
const [pkgPath, provenancePath] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
const provenance = JSON.parse(fs.readFileSync(provenancePath, "utf8"));
if (pkg.name !== "pi-plan-mode" || pkg.version !== "0.4.8") process.exit(1);
if (pkg.license !== "MIT" || !Array.isArray(pkg.pi?.extensions) || pkg.pi.extensions.length !== 1 || pkg.pi.extensions[0] !== "./plan-mode.ts") process.exit(2);
if (pkg.peerDependencies?.["@earendil-works/pi-ai"] !== "*" || pkg.peerDependencies?.["@earendil-works/pi-coding-agent"] !== ">=0.63.0 <1.0.0") process.exit(3);
if (Object.keys(pkg.peerDependencies || {}).some((name) => name.startsWith("@mariozechner/"))) process.exit(4);
if (provenance.version !== pkg.version || provenance.upstream?.repository !== "qmx/pi-plan-mode" || provenance.upstream?.pull_request !== 9 || !/^[0-9a-f]{40}$/.test(provenance.upstream?.commit || "")) process.exit(5);
if (provenance.npm?.integrity !== "sha512-UZ5mrHNiGgx69cgK01OWR5TzcYFsKiJQg4ERtz3a5wzUtElyR468Lci4JqxkDgbc1dYPUr58Q+YnIj9aEoRiUQ==") process.exit(6);
for (const [name, hash] of Object.entries(provenance.source_sha256 || {})) {
  if (!/^[0-9a-f]{64}$/.test(hash) || !fs.existsSync(require("node:path").join(require("node:path").dirname(provenancePath), name))) process.exit(7);
}
NODE

if grep -Eq '@mariozechner/pi-(coding-agent|ai|tui)' "$VENDOR_DIR/package.json" "$VENDOR_DIR/plan-mode.ts"; then
  fail "vendor source retained the legacy Pi scope"
fi
grep -Fq 'from "@earendil-works/pi-coding-agent"' "$VENDOR_DIR/plan-mode.ts" ||
  fail "vendor extension does not import the maintained Pi agent"
grep -Fq 'from "@earendil-works/pi-ai"' "$VENDOR_DIR/plan-mode.ts" ||
  fail "vendor extension does not import the maintained Pi AI package"
grep -Fq 'let planModeEnabled = true;' "$VENDOR_DIR/plan-mode.ts" ||
  fail "firmware vendor extension does not default new Pi sessions to plan mode"
grep -Fq 'Router agents begin each new session in plan mode' "$VENDOR_DIR/plan-mode.ts" ||
  fail "firmware vendor extension does not document the explicit write escape"
grep -Fq 'pi.setActiveTools(["read", "bash"]);' "$VENDOR_DIR/plan-mode.ts" ||
  fail "plan mode does not hide write tools before agent start"
grep -Fq 'event.toolName === "write" || event.toolName === "edit"' "$VENDOR_DIR/plan-mode.ts" ||
  fail "plan mode does not block direct write/edit calls"

for term in 'UPSTREAM_PULL_REQUEST=9' 'EXPECTED_SCOPE_PR_HEAD="8bf61ebb34647c1d22848fb951a2234965693cef"' 'dist.integrity' 'source_sha256' 'unexpected archive layout' 'scope migration' 'OpenWrt devices run untrusted/remote agent work'; do
  grep -Fq "$term" "$REFRESH_SCRIPT" || fail "refresh script lacks fail-closed guard: $term"
done
bash -n "$REFRESH_SCRIPT" || fail "refresh script does not parse"

grep -Fq '/tmp/agent-runtime-pi-plan-mode.ts' "$RECONCILE" ||
  fail "migration does not register the vendored extension path"
grep -Fq 'packages' "$RECONCILE" || fail "migration does not preserve Pi packages"
grep -Fq 'JSON.stringify(settings' "$RECONCILE" || fail "migration does not preserve Pi settings"

echo "pi-plan-mode vendor guard test passed"
