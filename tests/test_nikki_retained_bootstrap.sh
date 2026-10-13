#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/files/etc/init.d/nikki-subscription-bootstrap"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
cat > "$WORK/bin/uci" <<'EOF'
#!/bin/sh
case "$1" in
-q) cat "$TEST_STATE" ;;
set) printf '%s\n' "${2#*=}" > "$TEST_STATE" ;;
commit) : ;;
esac
EOF
cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/defaults" <<'EOF'
#!/bin/sh
# Model ROM firstboot reset and a subscription download that has no usable DNS.
printf '0\n' > "$TEST_STATE"
exit "${TEST_DEFAULT_FAIL:-0}"
EOF
cat > "$WORK/init" <<'EOF'
#!/bin/sh
case "$1" in
running) [ -f "$TEST_RUNNING" ] ;;
start) echo start >> "$TEST_STARTS"; touch "$TEST_RUNNING" ;;
esac
EOF
chmod +x "$WORK/bin/"* "$WORK/init"
export PATH="$WORK/bin:$PATH" TEST_STATE="$WORK/state" TEST_RUNNING="$WORK/running" TEST_STARTS="$WORK/starts"
export NIKKI_SUBSCRIPTION_BOOTSTRAP_DEFAULTS="$WORK/defaults" NIKKI_SUBSCRIPTION_BOOTSTRAP_CACHE_FILE="$WORK/cache.yaml" NIKKI_SUBSCRIPTION_BOOTSTRAP_NIKKI_INIT="$WORK/init"
run() { sh -c '. "$1"; start' sh "$BOOTSTRAP"; }
echo retained-cache > "$WORK/cache.yaml"
echo 1 > "$TEST_STATE"
run
[ "$(cat "$TEST_STATE")" = 1 ] && [ "$(cat "$TEST_STARTS")" = start ]
# A healthy retained daemon must not be started twice.
: > "$TEST_STARTS"
run
[ ! -s "$TEST_STARTS" ]
# Neither a disabled installation nor a missing cached subscription is enabled.
echo 0 > "$TEST_STATE"
run
[ "$(cat "$TEST_STATE")" = 0 ] && [ ! -s "$TEST_STARTS" ]
rm "$WORK/cache.yaml" "$TEST_RUNNING"
echo 1 > "$TEST_STATE"
run
[ "$(cat "$TEST_STATE")" = 0 ] && [ ! -s "$TEST_STARTS" ]
echo retained-cache > "$WORK/cache.yaml"
echo 1 > "$TEST_STATE"
if TEST_DEFAULT_FAIL=1 run; then echo 'failed private defaults must fail bootstrap' >&2; exit 1; fi
[ "$(cat "$TEST_STATE")" = 0 ] && [ ! -s "$TEST_STARTS" ]
echo 'Nikki retained bootstrap behavior tests passed'
