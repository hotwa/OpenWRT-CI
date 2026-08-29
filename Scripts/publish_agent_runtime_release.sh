#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Publish only the already signed complete agent-runtime release set.
set -euo pipefail

REPOSITORY="${GITHUB_REPOSITORY:-}"
TAG=""
DIRECTORY=""
die() { printf 'ERROR: [agent-runtime release] %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --directory) DIRECTORY="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$REPOSITORY" ] && [ -n "$TAG" ] && [ -d "$DIRECTORY" ] || die "repository, tag, and directory are required"
[ "$TAG" = "agent-runtime-stable" ] || die "only the fixed agent-runtime-stable tag may be published"
command -v gh >/dev/null 2>&1 || die "GitHub CLI is required"
for arch in arm64 x64; do
  base="$(find "$DIRECTORY" -maxdepth 1 -type f -name "agent-runtime-*-${arch}-musl.manifest.json" -print -quit)"
  [ -n "$base" ] && [ -r "$base.sig" ] || die "missing signed $arch manifest"
  bundle="${base%.manifest.json}.tar.gz"
  [ -r "$bundle" ] || die "missing $arch bundle"
done
[ -r "$DIRECTORY/index.json" ] && [ -r "$DIRECTORY/index.json.sig" ] || die "missing signed index"

notes="$(mktemp)"
trap 'rm -f -- "$notes"' EXIT
printf 'Verified OpenWrt agent-runtime generation. Install only through agent-runtime.\n' >"$notes"
if gh release view -R "$REPOSITORY" "$TAG" >/dev/null 2>&1; then
  gh release edit -R "$REPOSITORY" "$TAG" --title "$TAG" --notes-file "$notes" --latest=false
else
  gh release create -R "$REPOSITORY" "$TAG" --title "$TAG" --notes-file "$notes" --latest=false
fi
# Promote a complete channel deliberately: payloads and detached manifests
# first, index signature next, and index.json last as the atomic visibility
# pointer consumed by devices.
find "$DIRECTORY" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.manifest.json' -o -name '*.manifest.json.sig' \) -print0 |
  while IFS= read -r -d '' asset; do gh release upload -R "$REPOSITORY" "$TAG" "$asset" --clobber; done
gh release upload -R "$REPOSITORY" "$TAG" "$DIRECTORY/index.json.sig" --clobber
gh release upload -R "$REPOSITORY" "$TAG" "$DIRECTORY/index.json" --clobber
