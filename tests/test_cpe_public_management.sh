#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test "$ROOT_DIR/tests/test_cpe_public_access.mjs" "$ROOT_DIR/tests/test_cpe_origin_selector.mjs" "$ROOT_DIR/tests/test_cpe_lucky_origin.mjs" "$ROOT_DIR/tests/test_cpe_origin_certificate.mjs" "$ROOT_DIR/tests/test_cpe_lucky_private_restore.mjs" "$ROOT_DIR/tests/test_cpe_lucky_managed.mjs"
