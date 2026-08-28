#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/files/etc/config/multica"
INIT_SCRIPT="$ROOT_DIR/files/etc/init.d/multica"
ENROLL_SCRIPT="$ROOT_DIR/Scripts/MulticaAutoEnroll.sh"
CORE_WF="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

[ -f "$CONFIG_FILE" ] || { echo "missing multica config"; exit 1; }
[ -f "$INIT_SCRIPT" ] || { echo "missing multica init script"; exit 1; }
[ -f "$ENROLL_SCRIPT" ] || { echo "missing MulticaAutoEnroll.sh"; exit 1; }
[ -f "$CORE_WF" ] || { echo "missing WRT-CORE.yml"; exit 1; }

grep -Fq 'config multica' "$CONFIG_FILE"
grep -Fq 'workspaces_root' "$CONFIG_FILE"
grep -Fq 'daemon start --foreground' "$INIT_SCRIPT"
grep -Fq 'MULTICA_DAEMON_DEVICE_NAME' "$INIT_SCRIPT"
grep -Fq 'MULTICA_WORKSPACES_ROOT' "$INIT_SCRIPT"
grep -Fq 'MULTICA_TOKEN' "$ENROLL_SCRIPT"
grep -Fq 'MulticaAutoEnroll.sh' "$CORE_WF"

echo "multica auto-enroll guard tests passed"