#!/usr/bin/env bash
set -euo pipefail
# These fixtures exercise production root-owned certificate/quota files.
# GitHub's runner is unprivileged; run the fixture with its required owner.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -n -- env PATH="$PATH" bash "$0" "$@"
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test "$ROOT_DIR/tests/test_cpe_quota_ledger.mjs"
