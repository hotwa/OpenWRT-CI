#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUMP_SCRIPT="$ROOT_DIR/Scripts/bump_agent_runtime.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/Agent-Runtime-Bump.yml"
POLICY_DOC="$ROOT_DIR/docs/agent-runtime-version-policy.md"
AGENTS_DOC="$ROOT_DIR/AGENTS.md"
NODE_FETCH="$ROOT_DIR/Scripts/fetch_node_runtime.sh"
UV_FETCH="$ROOT_DIR/Scripts/fetch_uv_runtime.sh"
MULTICA_FETCH="$ROOT_DIR/Scripts/fetch_multica_runtime.sh"
CORE_WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
PACKAGE_JSON="$ROOT_DIR/Scripts/node-agent-runtime/package.json"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "agent runtime policy: $*"
  exit 1
}

for path in "$BUMP_SCRIPT" "$WORKFLOW" "$POLICY_DOC" "$AGENTS_DOC" "$NODE_FETCH" \
  "$UV_FETCH" "$MULTICA_FETCH" "$CORE_WORKFLOW" "$PACKAGE_JSON"; do
  [ -f "$path" ] || fail "missing $path"
done

bash -n "$BUMP_SCRIPT" || fail "bump_agent_runtime.sh does not parse"

# The bump engine is the only writer of the floating layer, and the guards below
# call its functions directly, which requires it to end by invoking main.
[ "$(tail -n1 "$BUMP_SCRIPT")" = 'main "$@"' ] ||
  fail "bump_agent_runtime.sh must end with main \"\$@\" so guards can source it"
sed '$d' "$BUMP_SCRIPT" >"$WORK_DIR/lib.sh"

run_as_lib() {
  (
    set -euo pipefail
    export GITHUB_WORKSPACE="$ROOT_DIR"
    # shellcheck disable=SC1090
    source "$WORK_DIR/lib.sh"
    [ -z "${TEST_PACKAGE_JSON:-}" ] || PACKAGE_JSON="$TEST_PACKAGE_JSON"
    "$@"
  )
}

# --- the automation must be wired to the engine, not to hand-written bumps ---
grep -q 'Scripts/bump_agent_runtime.sh' "$WORKFLOW" ||
  fail "Agent-Runtime-Bump.yml does not run the bump engine"
grep -q 'mode=apply' "$WORKFLOW" || fail "workflow never applies bumps"
grep -q 'mode=plan' "$WORKFLOW" || fail "workflow has no dry-run path"
grep -q 'cron:' "$WORKFLOW" || fail "workflow is not scheduled"
grep -q 'workflow_dispatch:' "$WORKFLOW" || fail "workflow is not manually dispatchable"
grep -q 'cancel-in-progress: false' "$WORKFLOW" ||
  fail "concurrent bumps must not cancel each other before the push"

# A gate failure must be able to fail the step: `cmd | tee` without pipefail
# reports tee's status, so every run block has to opt in explicitly.
awk '
  BEGIN { bad = 0 }
  /run: \|[[:space:]]*$/ {
    if ((getline next_line) <= 0 || next_line !~ /set -eu/) { bad = 1 }
  }
  END { exit bad }
' "$WORKFLOW" || fail "a workflow run block is missing 'set -euo pipefail'"

if grep -Eq -- '--no-verify|git push .*-f|--force' "$WORKFLOW"; then
  fail "workflow must not bypass hooks or force-push"
fi

# Commit/push must come after the gates, and only for the floating layer.
BUMP_STEP_LINE="$(grep -n 'bump_agent_runtime.sh' "$WORKFLOW" | head -n1 | cut -d: -f1)"
PUSH_STEP_LINE="$(grep -n 'git push' "$WORKFLOW" | head -n1 | cut -d: -f1)"
[ -n "$PUSH_STEP_LINE" ] || fail "workflow never pushes"
[ "$BUMP_STEP_LINE" -lt "$PUSH_STEP_LINE" ] ||
  fail "workflow pushes before the bump engine has verified anything"
for base in fetch_node_runtime.sh fetch_uv_runtime.sh; do
  if grep -q "$base" "$WORKFLOW"; then
    fail "Agent-Runtime-Bump.yml must not touch the pinned runtime base ($base)"
  fi
done

# --- the engine must gate before it declares itself committable ---
GUARD_LINE="$(grep -n '^[[:space:]]*run_guard_suite$' "$BUMP_SCRIPT" | tail -n1 | cut -d: -f1)"
READY_LINE="$(grep -n 'ready to commit' "$BUMP_SCRIPT" | head -n1 | cut -d: -f1)"
[ -n "$GUARD_LINE" ] && [ -n "$READY_LINE" ] || fail "bump engine lost its commit gate"
[ "$GUARD_LINE" -lt "$READY_LINE" ] ||
  fail "bump engine reports success before running the gates"
for cpu in arm64 x64; do
  grep -Eq "verify_target_cpu[[:space:]]+$cpu" "$BUMP_SCRIPT" ||
    fail "bump engine does not verify the linux-$cpu-musl install"
done

# The pinned base is read-only for the engine: every reference to it must be a read.
if grep -F 'UV_SCRIPT' "$BUMP_SCRIPT" | grep -Eq 'sed -i|install |cp |>>'; then
  fail "bump engine writes the pinned uv/CPython base"
fi

# --- build-time interlock: hermes' managed Python must exist in the mirror ---
grep -q '"pythonVersion"' "$NODE_FETCH" ||
  fail "fetch_node_runtime.sh no longer reads hermes-agent's managed pythonVersion"
grep -q 'opt/uv/python-mirror/manifest.txt' "$NODE_FETCH" ||
  fail "fetch_node_runtime.sh does not check the offline CPython mirror manifest"
grep -q 'HERMES_PYTHON_SERIES=' "$NODE_FETCH" ||
  fail "fetch_node_runtime.sh does not publish HERMES_PYTHON_SERIES"
grep -Eq 'PYTHON_SERIES in Scripts/fetch_uv_runtime\.sh' "$NODE_FETCH" ||
  fail "fetch_node_runtime.sh does not name PYTHON_SERIES in its failure hint"

# The interlock reads a manifest the uv step writes, so the call order is load-bearing.
UV_LINE="$(grep -n 'Scripts/fetch_uv_runtime.sh' "$CORE_WORKFLOW" | head -n1 | cut -d: -f1)"
NODE_LINE="$(grep -n 'Scripts/fetch_node_runtime.sh' "$CORE_WORKFLOW" | head -n1 | cut -d: -f1)"
MULTICA_LINE="$(grep -n 'Scripts/fetch_multica_runtime.sh' "$CORE_WORKFLOW" | head -n1 | cut -d: -f1)"
[ "$UV_LINE" -lt "$NODE_LINE" ] && [ "$NODE_LINE" -lt "$MULTICA_LINE" ] ||
  fail "WRT-CORE.yml must run fetch_uv_runtime.sh before fetch_node_runtime.sh"

# --- behaviour, not just text ---
if bash "$BUMP_SCRIPT" not-a-mode >"$WORK_DIR/mode.log" 2>&1; then
  fail "bump engine accepted an unknown mode"
fi
grep -q 'unknown mode' "$WORK_DIR/mode.log" ||
  fail "bump engine did not explain the rejected mode"

# The plan loop reads manifest_packages with `while read`, so a missing
# terminating newline silently drops the last dependency.
LISTED_FILE="$WORK_DIR/listed.txt"
EXPECTED_FILE="$WORK_DIR/expected.txt"
: >"$LISTED_FILE"
while IFS= read -r dep; do
  [ -n "$dep" ] && printf '%s\n' "$dep" >>"$LISTED_FILE"
done < <(run_as_lib manifest_packages)
node -e 'console.log(Object.keys(require(process.argv[1]).dependencies).join("\n"))' \
  "$PACKAGE_JSON" >"$EXPECTED_FILE"
cmp -s "$LISTED_FILE" "$EXPECTED_FILE" ||
  fail "manifest_packages listed $(wc -l <"$LISTED_FILE") of $(wc -l <"$EXPECTED_FILE") dependencies to the plan loop"

# Every floating pin must stay exact, or `npm ci` would resolve freely.
node -e '
  const deps = require(process.argv[1]).dependencies;
  const loose = Object.entries(deps).filter(([, v]) => !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(v));
  if (loose.length) process.stderr.write(loose.map(([k, v]) => `${k}@${v}`).join(", ") + "\n");
  process.exit(loose.length ? 5 : 0);
' "$PACKAGE_JSON" || fail "package.json contains a non-exact dependency pin (listed above)"

# The Multica and PYTHON_SERIES extraction patterns are the fragile part of the
# engine; prove they still match the real files.
[ "$(run_as_lib multica_current_version)" = \
  "$(grep -m1 '^MULTICA_VERSION=' "$MULTICA_FETCH" | sed -E 's/.*:-([0-9.]+).*/\1/')" ] ||
  fail "multica_current_version no longer parses $MULTICA_FETCH"
grep -q 'MULTICA_VERSION="\${MULTICA_VERSION:-' "$MULTICA_FETCH" ||
  fail "Multica pin is no longer overridable by the caller"
[ "$(run_as_lib python_series_mirror)" = \
  "$(grep -m1 '^PYTHON_SERIES=(' "$UV_FETCH" | sed -E 's/^PYTHON_SERIES=\((.*)\)$/\1/')" ] ||
  fail "python_series_mirror no longer parses $UV_FETCH"

# Rewriting package.json must move exactly one pin and keep the file committable.
cp "$PACKAGE_JSON" "$WORK_DIR/package.json.orig"
cp "$PACKAGE_JSON" "$WORK_DIR/package.json"
FIRST_DEP="$(head -n1 "$LISTED_FILE")"
TEST_PACKAGE_JSON="$WORK_DIR/package.json" \
  run_as_lib set_manifest_version "$FIRST_DEP" 9.9.9 ||
  fail "set_manifest_version refused a known dependency"
[ "$(grep -c '"9.9.9"' "$WORK_DIR/package.json")" = "1" ] ||
  fail "set_manifest_version leaked the test version into more than one entry"
cmp -s "$PACKAGE_JSON" "$WORK_DIR/package.json.orig" ||
  fail "set_manifest_version wrote the repository manifest instead of the fixture"
node -e '
  const fs = require("node:fs");
  const [a, b, name] = process.argv.slice(1);
  const before = JSON.parse(fs.readFileSync(a, "utf8"));
  const after = JSON.parse(fs.readFileSync(b, "utf8"));
  if (after.dependencies[name] !== "9.9.9") process.exit(1);
  delete before.dependencies[name];
  delete after.dependencies[name];
  if (JSON.stringify(before) !== JSON.stringify(after)) process.exit(2);
' "$WORK_DIR/package.json.orig" "$WORK_DIR/package.json" "$FIRST_DEP" ||
  fail "set_manifest_version changed more than the requested pin"
[ "$(tail -c1 "$WORK_DIR/package.json" | od -An -c | tr -d ' \n')" = '\n' ] ||
  fail "set_manifest_version dropped the trailing newline"
[ "$(tr -cd '\r' <"$WORK_DIR/package.json" | wc -c)" = "0" ] ||
  fail "set_manifest_version wrote CRLF line endings into package.json"

# The policy is only real if both documents point at the same enforcement.
grep -q 'agent-runtime-version-policy.md' "$AGENTS_DOC" ||
  fail "AGENTS.md does not route maintainers to the version policy"
for term in bump_agent_runtime.sh Agent-Runtime-Bump.yml PYTHON_SERIES WRT_COMMIT; do
  grep -q "$term" "$POLICY_DOC" ||
    fail "docs/agent-runtime-version-policy.md no longer documents $term"
done

echo "agent runtime policy tests passed"
