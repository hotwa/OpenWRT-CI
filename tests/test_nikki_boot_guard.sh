#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$root/files/usr/sbin/nikki-boot-guard"
init="$root/files/etc/init.d/nikki-boot-guard"
defaults="$root/files/etc/uci-defaults/99-enable-nikki-boot-guard"
workflow="$root/.github/workflows/WRT-CORE.yml"
sh -n "$guard" "$init" "$defaults"
grep -Fq 'nikki-boot-guard' "$workflow"
grep -Fq '/etc/init.d/nikki-boot-guard enable' "$defaults"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "${MOCK_ENABLED:-1}"
EOF
cat >"$work/bin/ip" <<'EOF'
#!/bin/sh
[ "${MOCK_WAN:-1}" = 1 ] && printf 'default via 192.0.2.1 dev wan\n'
EOF
cat >"$work/bin/pgrep" <<'EOF'
#!/bin/sh
[ -e "${MOCK_CORE_MARKER:?}" ]
EOF
cat >"$work/bin/timeout" <<'EOF'
#!/bin/sh
shift
"$@"
EOF
cat >"$work/bin/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_LOG:?}"
EOF
cat >"$work/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$work/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$work/init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"${MOCK_START_LOG:?}"
[ "${MOCK_START_CORE:-1}" = 1 ] && : >"${MOCK_CORE_MARKER:?}"
EOF
chmod +x "$work/bin"/* "$work/init"
export PATH="$work/bin:$PATH" MOCK_CORE_MARKER="$work/core" MOCK_LOG="$work/log" MOCK_START_LOG="$work/start"
export NIKKI_BOOT_GUARD_INIT="$work/init" NIKKI_BOOT_GUARD_LOCK="$work/lock" NIKKI_BOOT_GUARD_SYNC_LOCK="$work/sync-lock"
MOCK_ENABLED=0 "$guard"
[ ! -e "$work/start" ]
MOCK_WAN=0 "$guard"
[ ! -e "$work/start" ]
MOCK_START_CORE=1 "$guard"
grep -Fxq start "$work/start"
[ -e "$work/core" ]
MOCK_START_CORE=1 "$guard"
[ "$(wc -l <"$work/start")" -eq 1 ]
rm "$work/core"
if MOCK_START_CORE=0 "$guard"; then
  echo 'missing core unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'still absent' "$work/log"
echo 'nikki boot guard passed'
