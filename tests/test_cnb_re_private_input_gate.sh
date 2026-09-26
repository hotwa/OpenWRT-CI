#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
script=Scripts/cnb_re_private_input_gate.sh

for value in '' '<fill-me>' REPLACE_ME TODO; do
  if SAMBA_DEFAULT_PASSWORD="$value" bash "$script" >/dev/null 2>&1; then
    echo 'ERROR: missing/placeholder credential was accepted' >&2
    exit 1
  fi
done

synthetic=samba-test-credential-3123
output="$(SAMBA_DEFAULT_PASSWORD="$synthetic" bash "$script" 2>&1)" || {
  echo 'ERROR: nonempty synthetic build input failed' >&2
  exit 1
}
case "$output" in
  *"$synthetic"*) echo 'ERROR: synthetic credential leaked' >&2; exit 1 ;;
esac
printf '%s\n' 'CNB private build input gate tests passed'
