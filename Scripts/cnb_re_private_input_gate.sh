#!/usr/bin/env bash
# Manual build-only secret-import preflight. Never print imported values or env.
set -euo pipefail
set +x

if [ -z "${SAMBA_DEFAULT_PASSWORD:-}" ]; then
  echo 'ERROR: SAMBA_DEFAULT_PASSWORD is required for the default RE firmware profile' >&2
  exit 1
fi
case "$SAMBA_DEFAULT_PASSWORD" in
  '<'*|'${'*|'REPLACE'*|'TODO'*|'FILL'*)
    echo 'ERROR: SAMBA_DEFAULT_PASSWORD appears to be a placeholder' >&2
    exit 1 ;;
esac
unset SAMBA_DEFAULT_PASSWORD
printf '%s\n' 'Required private-build credential is present (value not displayed).'
printf '%s\n' 'Only the shared Samba build credential is inspected here; the replay enforces'
printf '%s\n' 'each profile requirement (for example the CPE-5G and QCA device activation key)'
printf '%s\n' 'and fails closed without printing any value.'
