#!/bin/sh
set -eu
TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 -B "$TEST_DIR/test_mwan3_nft_compat.py"
