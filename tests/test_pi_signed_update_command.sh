#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$root/files/etc/profile.d/25-pi-signed-update.sh"
sh -n "$profile"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/agent-runtime-auto-upgrade" <<'EOF'
#!/bin/sh
printf '%s\n' 'called' >>"${MOCK_RUNTIME_LOG:?}"
exit "${MOCK_RUNTIME_RC:-0}"
EOF
cat >"$work/bin/pi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_PI_LOG:?}"
EOF
chmod +x "$work/bin"/*
export MOCK_RUNTIME_LOG="$work/runtime" MOCK_PI_LOG="$work/pi"
export PI_RUNTIME_UPDATE_BIN="$work/bin/agent-runtime-auto-upgrade"
export PATH="$work/bin:$PATH" DATA_RUNTIME_STATE=fallback DATA_RUNTIME_ROOT=/root
sh -c '. "$1"; pi update; pi update --extensions; pi update --extension; pi --version' sh "$profile" 2>/dev/null
[ "$(wc -l <"$work/runtime")" -eq 3 ]
[ "$(grep -c '^called$' "$work/runtime")" -eq 3 ]
grep -Fxq -- '--version' "$work/pi"
if MOCK_RUNTIME_RC=7 sh -c '. "$1"; pi update' sh "$profile" 2>/dev/null; then
  echo 'signed updater failure was swallowed' >&2
  exit 1
fi
echo 'Pi signed update command passed'
