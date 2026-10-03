#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/firmware_artifact_crypto.py" encrypt "$@"
