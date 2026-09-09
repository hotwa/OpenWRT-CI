#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
LIB="$ROOT_DIR/Scripts/wrt_cache_lib.sh"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow" >&2; exit 1; }
[ -f "$LIB" ] || { echo "missing wrt_cache_lib.sh" >&2; exit 1; }
bash -n "$LIB"

fail() { echo "WRT cache identity guard failed: $*" >&2; exit 1; }

# --- workflow structural guards --------------------------------------------
for term in \
  'name: Compute Build Cache Identity' \
  'Scripts/wrt_cache_lib.sh' \
  'wrt_cache_file_digest' \
  'wrt_cache_tree_digest' \
  'wrt_cache_scope_from_manifest' \
  'wrt_cache_build_keys' \
  'Config/${WRT_CONFIG}.txt' \
  'Scripts/Packages.sh' \
  'Scripts/Handles.sh' \
  'Scripts/Settings.sh' \
  'WRT_CACHE_SCOPE=${cache_keys[0]}' \
  'WRT_CACHE_RESTORE_PREFIX=${cache_keys[1]}' \
  'WRT_CACHE_SAVE_KEY=${cache_keys[2]}' \
  'key: ${{ env.WRT_CACHE_SAVE_KEY }}' \
  'restore-keys: ${{ env.WRT_CACHE_RESTORE_PREFIX }}'; do
  grep -Fq "$term" "$WORKFLOW" || fail "missing $term"
done

# The old bug double-hashed `sha256sum <files>` (which embeds absolute paths).
if grep -Eq 'sha256sum[^\n]*\|[[:space:]]*sha256sum' "$WORKFLOW"; then
  fail "identity must not re-hash full sha256sum output (that bakes in absolute paths)"
fi

# Compatibility scope must not rotate by date/run; uniqueness lives on save key.
grep -Fq 'WRT_CACHE_DATE' "$WORKFLOW" && fail "scope must not rotate by date"
grep -Fq '$GITHUB_RUN_ID' "$WORKFLOW" || fail "save key must include GITHUB_RUN_ID"

# Required inputs must fail closed instead of degrading to a broad key.
grep -Fq 'required cache identity input missing/empty' "$WORKFLOW" || fail "missing required-input failure"

# --- behavioral: content digest ignores the absolute path ------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "same-content" > "$TMP/a.bin"
mkdir -p "$TMP/deep/nested"
cp "$TMP/a.bin" "$TMP/deep/nested/b.bin"
h1="$(bash "$LIB" file-digest "$TMP/a.bin")"
h2="$(bash "$LIB" file-digest "$TMP/deep/nested/b.bin")"
[ "$h1" = "$h2" ] || fail "file digest changed with the path: $h1 != $h2"

# Tree digest is stable across different absolute parent locations.
mkdir -p "$TMP/loc1/overlay/etc" "$TMP/loc2/overlay/etc"
echo x > "$TMP/loc1/overlay/etc/f"
echo y > "$TMP/loc1/overlay/top"
cp -r "$TMP/loc1/overlay/." "$TMP/loc2/overlay/"
t1="$(bash "$LIB" tree-digest "$TMP/loc1/overlay")"
t2="$(bash "$LIB" tree-digest "$TMP/loc2/overlay")"
[ "$t1" = "$t2" ] || fail "tree digest changed with absolute parent"

echo "WRT cache identity guards passed"
