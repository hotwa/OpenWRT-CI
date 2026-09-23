#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
RELEASE="$ROOT_DIR/.github/workflows/WRT-RELEASE.yml"

[ -f "$CORE" ] || { echo "missing WRT-CORE workflow"; exit 1; }
[ -f "$RELEASE" ] || { echo "missing WRT-RELEASE workflow"; exit 1; }

check_pinned_actions() {
  local workflow="$1" action ref count=0
  while IFS= read -r action; do
    [ -n "$action" ] || continue
    case "$action" in
      ./*) continue ;;
    esac
    count=$((count + 1))
    ref="${action##*@}"
    if ! printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
      echo "$(basename "$workflow") uses a mutable external Action ref: $action"
      exit 1
    fi
  done < <(sed -n -E 's/^[[:space:]]*uses:[[:space:]]*([^#[:space:]]+).*/\1/p' "$workflow")
  [ "$count" -gt 0 ] || {
    echo "$(basename "$workflow") contains no external Action pins"
    exit 1
  }
}

check_pinned_actions "$CORE"
check_pinned_actions "$RELEASE"

grep -Fq '  build:' "$CORE"
grep -Fq '  release:' "$CORE"
grep -Fq 'contents: read' "$CORE"
grep -Fq 'actions: read' "$CORE"
grep -Fq 'name: Define Public Release Input' "$CORE"
grep -Fq 'name: Upload Immutable Public Release Input' "$CORE"
grep -Fq 'overwrite: false' "$CORE"
grep -Fq 'uses: ./.github/workflows/WRT-RELEASE.yml' "$CORE"

if grep -Eq 'gh[[:space:]]+release|HEADSCALE_CD_AUTHKEY|WRT_CD_TAILSCALE|TailscaleSysupgradeDeploy' "$CORE"; then
  echo "WRT-CORE build boundary still contains release or deployment capability"
  exit 1
fi

grep -Fq 'workflow_call:' "$RELEASE"
grep -Fq 'artifact_name:' "$RELEASE"
grep -Fq 'release_tag:' "$RELEASE"
grep -Fq 'contents: write' "$RELEASE"
grep -Fq 'actions: read' "$RELEASE"
grep -Fq 'actions/download-artifact@018cc2cf5baa6db3ef3c5f8a56943fffe632ef53 # v6.0.0' "$RELEASE"
grep -Fq 'sha256sum --check --strict' "$RELEASE"
grep -Fq 'metadata.json is missing' "$RELEASE"
grep -Fq 'SHA256SUMS does not cover exactly the release payload' "$RELEASE"
grep -Fq 'gh release create -R "$GITHUB_REPOSITORY"' "$RELEASE"
grep -Fq 'gh release upload -R "$GITHUB_REPOSITORY"' "$RELEASE"

if grep -Eq 'HEADSCALE_CD_AUTHKEY|WRT_CD_TAILSCALE|TailscaleSysupgradeDeploy|secrets:' "$RELEASE"; then
  echo "WRT-RELEASE must not receive deployment or repository secrets"
  exit 1
fi

echo "release boundary guards passed"
