#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$WORKFLOW" ] || { echo "missing WRT-CORE workflow"; exit 1; }

action_count=0
while IFS= read -r action; do
  [ -n "$action" ] || continue
  action_count=$((action_count + 1))
  ref="${action##*@}"
  if ! printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "WRT-CORE uses a mutable external Action ref: $action"
    exit 1
  fi
done < <(sed -n -E 's/^[[:space:]]*uses:[[:space:]]*([^#[:space:]]+).*/\1/p' "$WORKFLOW")
[ "$action_count" -ge 5 ] || {
  echo "WRT-CORE action pin test did not inspect the expected actions"
  exit 1
}

grep -Fq 'endersonmenezes/free-disk-space@713d134e243b926eba4a5cce0cf608bfd1efb89a # v2.1.1' "$WORKFLOW"
grep -Fq 'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0' "$WORKFLOW"
grep -Fq 'actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0' "$WORKFLOW"
grep -Fq 'node-version: 24.20.0' "$WORKFLOW"

grep -q 'name: Upload Firmware Artifact' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not upload firmware artifacts before release"
  exit 1
}

grep -q 'uses: actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f # v6.0.0' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not use the SHA-pinned Node24 upload-artifact v6 action"
  exit 1
}

if grep -q 'uses: actions/upload-artifact@v4' "$WORKFLOW"; then
  echo "WRT-CORE.yml still uses upload-artifact@v4, which targets Node.js 20"
  exit 1
fi

grep -q 'uses: actions/cache@caa296126883cff596d87d8935842f9db880ef25 # v5.1.0' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not use the SHA-pinned Node24 cache v5 action"
  exit 1
}

if grep -q 'uses: actions/cache@v4' "$WORKFLOW"; then
  echo "WRT-CORE.yml still uses cache@v4, which targets Node.js 20"
  exit 1
fi

grep -q 'name: Release Firmware' "$WORKFLOW" || {
  echo "WRT-CORE.yml is missing the Release Firmware step"
  exit 1
}

grep -q 'gh release create' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not use the official gh CLI to create releases"
  exit 1
}

grep -q 'gh release upload' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not use the official gh CLI to upload release assets"
  exit 1
}

grep -q 'gh release create -R "$GITHUB_REPOSITORY"' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not force gh release create to target the workflow repository"
  exit 1
}

grep -q 'gh release upload -R "$GITHUB_REPOSITORY"' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not force gh release upload to target the workflow repository"
  exit 1
}

grep -q 'WRT_INFO_VALUE="${WRT_SOURCE%%/\*}"' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not compute a fallback release filename prefix"
  exit 1
}

grep -q 'GH_TOKEN: ${{secrets.GITHUB_TOKEN}}' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not pass GITHUB_TOKEN to gh as GH_TOKEN"
  exit 1
}

grep -q 'actions: write' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not grant actions: write permission for cache cleanup"
  exit 1
}

grep -q 'retry_cmd 5 15 gh release upload' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not retry gh release upload"
  exit 1
}

grep -q 'for asset in "${assets\[@\]}"; do' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not upload release assets one by one"
  exit 1
}

grep -q 'WARN: failed to delete cache \$key' "$WORKFLOW" || {
  echo "WRT-CORE.yml does not tolerate cache deletion failures"
  exit 1
}

echo "release fallback guards test passed"
