#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/files/etc/init.d/agent-data-prep"
PI_SETTINGS_MERGER="$ROOT_DIR/files/usr/sbin/pi-settings-merge.js"
ENABLE_SCRIPT="$ROOT_DIR/files/etc/uci-defaults/99-enable-data-runtime"
CORE_WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Syntax check
# ---------------------------------------------------------------------------
sh -n "$SCRIPT"
node --check "$PI_SETTINGS_MERGER"

# ---------------------------------------------------------------------------
# Fixture: firmware defaults + empty data partition + /root with old overlay
# ---------------------------------------------------------------------------
FW="$TMP_ROOT/etc"
DATA="$TMP_ROOT/data"
ROOT="$TMP_ROOT/root"
mkdir -p "$FW/pi/agent" "$FW/commandcode" "$FW/multica" "$FW/opencode"
mkdir -p "$DATA" "$ROOT"

cp "$ROOT_DIR/files/etc/pi/agent/settings.json" "$FW/pi/agent/settings.json"
cat > "$FW/pi/agent/auth.json" <<'JSON'
{"apiKey":"firmware-key-123"}
JSON
printf '%s\n' '{"apiKey":"firmware-cc-key-456"}' > "$FW/commandcode/auth.json"
printf '%s\n' '{"permission":"allow","provider":{"commandcode":{"options":{"apiKey":"{env:COMMANDCODE_API_KEY}"}},"local-sglang":{"options":{}}}}' > "$FW/opencode/opencode.json"
printf '%s\n' '# OpenWrt agent role card' > "$FW/multica/openwrt-agent.md"

# Simulate an overlay-only /root/.pi from the pre-/data era.
mkdir -p "$ROOT/.pi/agent"
cat > "$ROOT/.pi/agent/settings.json" <<'JSON'
{
  "defaultProvider": "openai",
  "customUserField": { "preserved": true },
  "packages": [
    "user-private-extension",
    "npm:pi-undo-redo",
    "pi-commandcode-provider@0.7.1",
    "npm:@router-for-me/pi-cliproxyapi-provider@1.2.3",
    "git+https://github.com/example/pi-custom.git#v1",
    "https://example.invalid/pi-custom.tgz",
    "file:../pi-custom",
    "./extensions/local.ts",
    "/opt/pi/local.js"
  ]
}
JSON
chmod 0600 "$ROOT/.pi/agent/settings.json"
user_settings_uid="$(stat -c '%u' "$ROOT/.pi/agent/settings.json")"
user_settings_gid="$(stat -c '%g' "$ROOT/.pi/agent/settings.json")"

# Simulate an npm cache that an older build left on the root overlay.
mkdir -p "$ROOT/.npm/_cacache/content-v2"
printf 'legacy-overlay-cache\n' > "$ROOT/.npm/_cacache/content-v2/blob"

# /data mount appears in the fake mounts file.
MOUNTS="$TMP_ROOT/mounts"
printf '/dev/mmcblk0p27 %s ext4 rw,noatime 0 0\n' "$DATA" > "$MOUNTS"

export AGENT_DATA_PREP_TESTING=1
export AGENT_DATA_PREP_ROOT="$DATA"
export AGENT_DATA_PREP_HOME="$ROOT"
export AGENT_DATA_PREP_FIRMWARE_ETC="$FW"
export AGENT_DATA_PREP_PROC_MOUNTS="$MOUNTS"
export AGENT_DATA_PREP_NODE_BIN="$(command -v node)"
export AGENT_DATA_PREP_PI_SETTINGS_MERGER="$PI_SETTINGS_MERGER"
# shellcheck source=/dev/null
. "$SCRIPT"

pass_count=0
fail_count=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc"
        fail_count=$((fail_count + 1))
    fi
}

npm_guards_in_all_builds() {
	grep -q 'cp -f ./files/etc/npmrc ./wrt/files/etc/npmrc' "$CORE_WORKFLOW" && \
		grep -q 'cp -f ./files/root/.npmrc ./wrt/files/root/.npmrc' "$CORE_WORKFLOW" && \
		grep -q 'cp -f ./files/.npmrc ./wrt/files/.npmrc' "$CORE_WORKFLOW"
}

pi_settings_merger_in_all_builds() {
	grep -q 'cp -f ./files/usr/sbin/pi-settings-merge.js ./wrt/files/usr/sbin/pi-settings-merge.js' "$CORE_WORKFLOW" && \
		grep -q './wrt/files/usr/sbin/pi-settings-merge.js' "$CORE_WORKFLOW"
}

pi_settings_preserved_and_merged() {
	node - "$DATA/pi/agent/settings.json" <<'NODE'
const fs = require('node:fs');
const [settingsPath] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
const required = ['pi-undo-redo', 'pi-inspect', 'pi-lsp', 'pi-cache-graph', 'pi-cost'];
const packageIdentities = new Set(settings.packages?.map(name => name.replace(/^npm:/, '')));
if (settings.defaultProvider !== 'openai') process.exit(1);
if (settings.customUserField?.preserved !== true) process.exit(2);
if (!settings.packages?.includes('user-private-extension')) process.exit(3);
for (const packageName of required) {
  if (!packageIdentities.has(packageName)) process.exit(4);
}
if (!settings.packages.includes('npm:pi-undo-redo')) process.exit(5);
if (settings.packages.includes('pi-undo-redo')) process.exit(6);
const undoEntries = settings.packages.filter(name => name.replace(/^npm:/, '') === 'pi-undo-redo');
if (undoEntries.length !== 1) process.exit(7);
if (!settings.packages.includes('pi-commandcode-provider@0.7.1')) process.exit(8);
if (settings.packages.includes('npm:pi-commandcode-provider')) process.exit(9);
if (!settings.packages.includes('npm:@router-for-me/pi-cliproxyapi-provider@1.2.3')) process.exit(10);
if (settings.packages.includes('npm:@router-for-me/pi-cliproxyapi-provider')) process.exit(11);
for (const literal of [
  'git+https://github.com/example/pi-custom.git#v1',
  'https://example.invalid/pi-custom.tgz',
  'file:../pi-custom',
  './extensions/local.ts',
  '/opt/pi/local.js',
]) {
  if (!settings.packages.includes(literal)) process.exit(12);
}
NODE
}

pi_settings_registry_and_literal_specs() {
	node - "$PI_SETTINGS_MERGER" "$TMP_ROOT/spec-merge" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const [merger, work] = process.argv.slice(2);
fs.mkdirSync(work, { recursive: true });
const firmwarePath = path.join(work, 'firmware.json');
const persistentPath = path.join(work, 'persistent.json');
const firmwareLiterals = [
  'git+https://github.com/example/pi-custom.git#firmware',
  'https://example.invalid/pi-custom-firmware.tgz',
  'file:../pi-custom-firmware',
  './extensions/firmware.ts',
  '/opt/pi/firmware.js',
];
const userLiterals = [
  'git+https://github.com/example/pi-custom.git#user',
  'https://example.invalid/pi-custom-user.tgz',
  'file:../pi-custom-user',
  './extensions/user.ts',
  '/opt/pi/user.js',
];
fs.writeFileSync(firmwarePath, JSON.stringify({
  packages: ['npm:pi-commandcode-provider', 'npm:@example/scoped-plugin', ...firmwareLiterals],
}));
fs.writeFileSync(persistentPath, JSON.stringify({
  packages: ['pi-commandcode-provider@0.7.1', 'npm:@example/scoped-plugin@1.2.3', ...userLiterals],
}));
const result = spawnSync(process.execPath, [merger, firmwarePath, persistentPath], { encoding: 'utf8' });
if (result.status !== 0) process.exit(1);
if (!/^changed [0-9]+:[0-9]+:[0-9]+:[0-9]+$/.test(result.stdout.trim())) process.exit(5);
const packages = JSON.parse(fs.readFileSync(persistentPath, 'utf8')).packages;
if (!packages.includes('pi-commandcode-provider@0.7.1') ||
    packages.includes('npm:pi-commandcode-provider')) process.exit(2);
if (!packages.includes('npm:@example/scoped-plugin@1.2.3') ||
    packages.includes('npm:@example/scoped-plugin')) process.exit(3);
for (const literal of [...firmwareLiterals, ...userLiterals]) {
  if (!packages.includes(literal)) process.exit(4);
}
const unchanged = spawnSync(process.execPath, [merger, firmwarePath, persistentPath], { encoding: 'utf8' });
if (unchanged.status !== 0 || unchanged.stdout.trim() !== 'unchanged') process.exit(6);
NODE
}

check "first-boot defaults enable agent-data-prep" \
	grep -q '/etc/init.d/agent-data-prep enable' "$ENABLE_SCRIPT"
check "all-build data baseline includes agent-data-prep" \
	grep -q 'cp -f ./files/etc/init.d/agent-data-prep ./wrt/files/etc/init.d/agent-data-prep' "$CORE_WORKFLOW"
check "all-build data baseline includes npm config guards" npm_guards_in_all_builds
check "all-build data baseline includes executable Pi settings merger" pi_settings_merger_in_all_builds
check "Pi settings merger normalizes registry versions but preserves literal specs" pi_settings_registry_and_literal_specs

# ---------------------------------------------------------------------------
# 1. First run provisions everything
# ---------------------------------------------------------------------------
start

check "wait_data_mount sees /data mount" wait_data_mount
check "/data/pi/agent/settings.json copied from firmware" test -f "$DATA/pi/agent/settings.json"
check "/data/pi/agent/auth.json copied from firmware" test -f "$DATA/pi/agent/auth.json"
check "/data/commandcode/auth.json matches firmware key" cmp -s "$FW/commandcode/auth.json" "$DATA/commandcode/auth.json"
check "/root/.pi is symlink to /data/pi" test -L "$ROOT/.pi"
check "/root/.pi target is /data/pi" test "$(readlink "$ROOT/.pi")" = "$DATA/pi"
check "/root/.multica is symlink to /data/multica" test -L "$ROOT/.multica"
check "/root/.commandcode is symlink to /data/commandcode" test -L "$ROOT/.commandcode"
check "/root/.npm is symlink to /data/cache/npm" test -L "$ROOT/.npm"
check "/root/.npm target is /data/cache/npm" test "$(readlink "$ROOT/.npm")" = "$DATA/cache/npm"
check "legacy overlay npm cache migrated into /data" cmp -s "$ROOT/.npm/_cacache/content-v2/blob" "$DATA/cache/npm/_cacache/content-v2/blob"
check "/root/.config/opencode symlink created" test -L "$ROOT/.config/opencode"
check "opencode config seeded from firmware" cmp -s "$FW/opencode/opencode.json" "$DATA/opencode/config/opencode.json"
check "multica role card copied" cmp -s "$FW/multica/openwrt-agent.md" "$DATA/multica/openwrt-agent.md"
check "old overlay settings migrated into /data/pi/agent" grep -q '"defaultProvider": "openai"' "$DATA/pi/agent/settings.json"
check "Pi settings preserve user fields and merge all firmware packages" pi_settings_preserved_and_merged
check "Pi settings merge preserves restrictive file mode" test "$(stat -c '%a' "$DATA/pi/agent/settings.json")" = 600
check "Pi settings merge preserves file owner" test "$(stat -c '%u' "$DATA/pi/agent/settings.json")" = "$user_settings_uid"
check "Pi settings merge preserves file group" test "$(stat -c '%g' "$DATA/pi/agent/settings.json")" = "$user_settings_gid"
check "Pi settings merge leaves no temporary file" test -z "$(find "$DATA/pi/agent" -maxdepth 1 -name '.settings.json.new.*' -print)"

# ---------------------------------------------------------------------------
# 2. Second run is idempotent (no symlink churn, no extra backups)
# ---------------------------------------------------------------------------
pi_link_before="$(readlink "$ROOT/.pi")"
npm_link_before="$(readlink "$ROOT/.npm")"
backups_before="$(find "$DATA" -name '*.bak.*' | wc -l)"
settings_inode_before="$(stat -c '%i' "$DATA/pi/agent/settings.json")"
start
check "second run leaves /root/.pi symlink intact" test "$(readlink "$ROOT/.pi")" = "$pi_link_before"
check "second run leaves /root/.npm symlink intact" test "$(readlink "$ROOT/.npm")" = "$npm_link_before"
check "second run adds no new backups" test "$(find "$DATA" -name '*.bak.*' | wc -l)" = "$backups_before"
check "second run does not duplicate auth files" test "$(find "$DATA/commandcode" -name 'auth.json*' | wc -l)" -ge 1
check "second run does not rewrite already-merged Pi settings" test "$(stat -c '%i' "$DATA/pi/agent/settings.json")" = "$settings_inode_before"
check "second run does not duplicate Pi packages" pi_settings_preserved_and_merged

# ---------------------------------------------------------------------------
# 3. Stale CommandCode key is replaced (with backup)
# ---------------------------------------------------------------------------
printf '%s\n' '{"apiKey":"stale-expired-key"}' > "$DATA/commandcode/auth.json"
start
check "stale CommandCode key replaced by firmware key" cmp -s "$FW/commandcode/auth.json" "$DATA/commandcode/auth.json"
check "stale key kept as timestamped backup" test -n "$(find "$DATA/commandcode" -name 'auth.json.bak.*' | head -1)"

# ---------------------------------------------------------------------------
# 4. Firmware-management marker follows only an originally managed rewrite
# ---------------------------------------------------------------------------
SETTINGS_MARKER="$DATA/pi/agent/.firmware-settings-managed"

write_unmerged_pi_settings() {
	cat > "$DATA/pi/agent/settings.json" <<'JSON'
{"defaultProvider":"openai","packages":["user-private-extension"]}
JSON
}

# Originally managed: a successful atomic rewrite must advance the existing
# marker to the new settings mtime without replacing the marker inode.
rm -f "$SETTINGS_MARKER"
write_unmerged_pi_settings
touch -t 200001010000 "$DATA/pi/agent/settings.json"
: > "$SETTINGS_MARKER"
touch -r "$DATA/pi/agent/settings.json" "$SETTINGS_MARKER"
managed_marker_inode="$(stat -c '%i' "$SETTINGS_MARKER")"
reconcile_pi_settings_packages
check "managed Pi settings merge performed an atomic rewrite" test "$PI_SETTINGS_MERGE_REWRITTEN" -eq 1
check "managed settings marker keeps its inode" test "$(stat -c '%i' "$SETTINGS_MARKER")" = "$managed_marker_inode"
check "managed settings marker follows rewritten settings mtime" test \
	"$(stat -c '%Y' "$SETTINGS_MARKER")" = "$(stat -c '%Y' "$DATA/pi/agent/settings.json")"

# User-edited: a mismatched marker must remain untouched even though packages
# are appended to settings.
write_unmerged_pi_settings
touch -t 200101010000 "$DATA/pi/agent/settings.json"
touch -t 200001010000 "$SETTINGS_MARKER"
user_marker_mtime="$(stat -c '%Y' "$SETTINGS_MARKER")"
reconcile_pi_settings_packages
check "user-edited Pi settings are still merged append-only" test "$PI_SETTINGS_MERGE_REWRITTEN" -eq 1
check "user-edited settings marker mtime remains unchanged" test \
	"$(stat -c '%Y' "$SETTINGS_MARKER")" = "$user_marker_mtime"

# Marker absent: reconciliation must not create one.
rm -f "$SETTINGS_MARKER"
write_unmerged_pi_settings
reconcile_pi_settings_packages
check "Pi settings merge does not create a missing managed marker" test ! -e "$SETTINGS_MARKER"

# Symlink marker: never follow it, even when its target mtime initially matches
# settings and would otherwise look firmware-managed.
write_unmerged_pi_settings
marker_target="$TMP_ROOT/marker-target"
: > "$marker_target"
touch -t 200001010000 "$DATA/pi/agent/settings.json" "$marker_target"
ln -s "$marker_target" "$SETTINGS_MARKER"
marker_target_mtime="$(stat -c '%Y' "$marker_target")"
reconcile_pi_settings_packages
check "Pi settings merge leaves symlink marker intact" test -L "$SETTINGS_MARKER"
check "Pi settings merge never follows symlink marker" test \
	"$(stat -c '%Y' "$marker_target")" = "$marker_target_mtime"

# Simulate an administrator atomically replacing settings after the package
# merge's rename but before marker refresh. The captured merged-file state must
# no longer match, so the formerly managed marker stays untouched.
rm -f "$SETTINGS_MARKER"
write_unmerged_pi_settings
touch -t 200001010000 "$DATA/pi/agent/settings.json"
: > "$SETTINGS_MARKER"
touch -r "$DATA/pi/agent/settings.json" "$SETTINGS_MARKER"
post_merge_marker_state="$(stat -c '%d:%i:%Y' "$SETTINGS_MARKER")"
post_merge_marker_mtime="$(stat -c '%Y' "$SETTINGS_MARKER")"
merge_pi_settings_packages
post_merge_settings_state="$PI_SETTINGS_MERGED_STATE"
check "post-merge race fixture performed an atomic rewrite" test \
	"$PI_SETTINGS_MERGE_REWRITTEN" -eq 1
cat > "$DATA/pi/agent/settings.json.user-new" <<'JSON'
{"defaultProvider":"administrator-edit","packages":["user-private-extension"]}
JSON
mv "$DATA/pi/agent/settings.json.user-new" "$DATA/pi/agent/settings.json"
refresh_pi_settings_managed_marker \
	"$DATA/pi/agent/settings.json" "$SETTINGS_MARKER" \
	"$post_merge_marker_state" "$post_merge_settings_state"
check "post-merge administrator replacement is preserved" \
	grep -Fq '"defaultProvider":"administrator-edit"' "$DATA/pi/agent/settings.json"
check "post-merge administrator replacement leaves managed marker untouched" test \
	"$(stat -c '%Y' "$SETTINGS_MARKER")" = "$post_merge_marker_mtime"

# ---------------------------------------------------------------------------
# 5. Invalid persistent Pi JSON fails open without replacing user data
# ---------------------------------------------------------------------------
printf '%s\n' '{invalid-json' > "$DATA/pi/agent/settings.json"
cp "$DATA/pi/agent/settings.json" "$TMP_ROOT/invalid-settings.before"
invalid_merge_log="$(start 2>&1)"
check "invalid Pi settings are preserved byte-for-byte" cmp -s "$TMP_ROOT/invalid-settings.before" "$DATA/pi/agent/settings.json"
check "invalid Pi settings emit a fail-open warning" \
	grep -Fq 'cannot merge default Pi packages; persistent settings preserved' <<<"$invalid_merge_log"
check "failed Pi settings merge leaves no temporary file" test -z "$(find "$DATA/pi/agent" -maxdepth 1 -name '.settings.json.new.*' -print)"

# ---------------------------------------------------------------------------
# 6. /data missing -> start is a no-op that returns 0
# ---------------------------------------------------------------------------
export AGENT_DATA_PREP_PROC_MOUNTS="$TMP_ROOT/no-mounts"
printf '' > "$TMP_ROOT/no-mounts"
rm -rf "$DATA"
mkdir -p "$DATA"   # overlay-style dir exists but is NOT a real mount
# Exercise all 45 bounded polling iterations without adding 90 seconds to this
# focused unit test.
sleep() { :; }
start
unset -f sleep
check "start with no /data mount exits cleanly" true
check "no provisioning happened without a real mount" test -z "$(ls -A "$DATA")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "===== agent-data-prep tests: $pass_count passed, $fail_count failed ====="
if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
echo "All agent-data-prep tests passed"
