#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Sign an already verified manifest and index with OpenWrt usign.
set -euo pipefail

KEY="${AGENT_RUNTIME_USIGN_SECRET_KEY_FILE:-}"
PUBLIC_KEY=""
MANIFEST=""
INDEX=""
die() { printf 'ERROR: [agent-runtime signing] %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) KEY="${2:-}"; shift 2 ;;
    --public-key) PUBLIC_KEY="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --index) INDEX="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$KEY" ] || die "AGENT_RUNTIME_USIGN_SECRET_KEY is required for a non-dry-run release"
[ -r "$KEY" ] || die "private signing key is not readable"
[ -r "$PUBLIC_KEY" ] || die "firmware public key is not readable"
[ -r "$MANIFEST" ] && [ -r "$INDEX" ] || die "manifest and index are required"
command -v usign >/dev/null 2>&1 || die "OpenWrt usign is required"

challenge="$(mktemp)"
challenge_sig="${challenge}.sig"
trap 'rm -f -- "$challenge" "$challenge_sig"' EXIT
printf 'agent-runtime signing-key match check\n' >"$challenge"
usign -S -m "$challenge" -s "$KEY" -x "$challenge_sig"
usign -V -m "$challenge" -p "$PUBLIC_KEY" -x "$challenge_sig" ||
  die "private key does not match the committed firmware public key"
for input in "$MANIFEST" "$INDEX"; do
  usign -S -m "$input" -s "$KEY" -x "$input.sig"
  usign -V -m "$input" -p "$PUBLIC_KEY" -x "$input.sig" || die "self-verification failed for $(basename "$input")"
done
printf 'signed %s and %s\n' "$MANIFEST" "$INDEX"
