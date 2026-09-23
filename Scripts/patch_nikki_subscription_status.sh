#!/bin/sh
# Apply the reviewed update_subscription() exit-status fix to the exact Nikki
# source revision selected by Scripts/Packages.sh.  Keep this transformation
# deliberately narrow: a changed upstream shape fails the build rather than
# silently producing a subscription worker that mistakes a failed download for
# success.
set -eu

[ "$#" -eq 1 ] || {
  echo 'usage: patch_nikki_subscription_status.sh <nikki.init>' >&2
  exit 2
}

INIT_FILE="$1"
TEMP_FILE="${INIT_FILE}.new.$$"
[ -f "$INIT_FILE" ] && [ ! -L "$INIT_FILE" ] || {
  echo "ERROR: Nikki init script is missing or unsafe: $INIT_FILE" >&2
  exit 1
}

awk '
  /^update_subscription\(\)[[:space:]]*\{/ { inside = 1 }
  inside && /^[[:space:]]*uci_commit "nikki"[[:space:]]*$/ {
    print
    print "\tif [ \"$success\" = 1 ]; then"
    print "\t\treturn 0"
    print "\tfi"
    print "\treturn 1"
    fixed += 1
    next
  }
  { print }
  END { exit fixed == 1 ? 0 : 1 }
' "$INIT_FILE" >"$TEMP_FILE" || {
  echo 'ERROR: Nikki update_subscription() shape is not the reviewed source.' >&2
  exit 1
}

mv -f "$TEMP_FILE" "$INIT_FILE"
