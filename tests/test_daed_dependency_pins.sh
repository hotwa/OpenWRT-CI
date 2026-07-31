#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAED_MAKEFILE="$ROOT_DIR/patches/daed/Makefile"

[ -f "$DAED_MAKEFILE" ] || { echo "missing daed Makefile patch"; exit 1; }

OUTBOUND_SHA="52c26f8e759e156d2f5ec97d18590febf74ba8bb"
QUIC_GO_SHA="e0d255ff807c0cdfa18e564b4db8967fd033643e"

grep -Fq "OUTBOUND_VERSION:=$OUTBOUND_SHA" "$DAED_MAKEFILE" || {
  echo "daed outbound source is not pinned to the reviewed compatible revision"
  exit 1
}

grep -Fq "QUIC_GO_VERSION:=$QUIC_GO_SHA" "$DAED_MAKEFILE" || {
  echo "daed quic-go source is not pinned to the reviewed compatible revision"
  exit 1
}

grep -Fq 'git -C $(DAED_BUILD_DIR)/outbound checkout --detach $(OUTBOUND_VERSION)' "$DAED_MAKEFILE" || {
  echo "daed outbound checkout does not enforce the pinned revision"
  exit 1
}

grep -Fq 'git -C $(DAED_BUILD_DIR)/quic-go checkout --detach $(QUIC_GO_VERSION)' "$DAED_MAKEFILE" || {
  echo "daed quic-go checkout does not enforce the pinned revision"
  exit 1
}

if grep -Eq 'git clone .* -b perf/(complete-optimizations|node-pooling-v2)' "$DAED_MAKEFILE"; then
  echo "daed still clones a moving performance branch without an exact checkout"
  exit 1
fi

if grep -Eq '(^|[[:space:]])(\$\(DAED_HOST_GO\)|go) (get -u|mod tidy)' "$DAED_MAKEFILE"; then
  echo "daed still upgrades or rewrites Go dependencies during the build"
  exit 1
fi

echo "daed dependency pin test passed"
