#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INJECTOR="$ROOT_DIR/Scripts/NikkiSubscriptionConfig.sh"
SYNC="$ROOT_DIR/files/usr/sbin/nikki-subscription-sync"
INIT="$ROOT_DIR/files/etc/init.d/nikki-subscription-sync"
HOTPLUG="$ROOT_DIR/files/etc/hotplug.d/iface/99-nikki-subscription"
CRON="$ROOT_DIR/files/etc/uci-defaults/99-nikki-subscription-cron"
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

for path in "$INJECTOR" "$SYNC" "$INIT" "$HOTPLUG" "$CRON"; do
  [ -f "$path" ] || { echo "missing $path"; exit 1; }
done

bash -n "$INJECTOR"
sh -n "$SYNC"
sh -n "$INIT"
sh -n "$HOTPLUG"
sh -n "$CRON"

grep -Fq 'NIKKI_SUBSCRIPTION_URL' "$INJECTOR"
grep -Fq 'NIKKI_SUBSCRIPTION_URL' "$WORKFLOW"
grep -Fq 'NIKKI_SUBSCRIPTION_URL: ${{ secrets.NIKKI_SUBSCRIPTION_URL }}' "$ROOT_DIR/.github/workflows/WLG-RE-CS-07-BUILD.yml"
grep -Fq 'ubus call network.interface.wan status' "$SYNC"
grep -Fq 'service nikki update_subscription' "$SYNC"
grep -Fq 'nikki.config.enabled=' "$SYNC"
grep -Fq 'NIKKI_SUBSCRIPTION_NIKKI_INIT' "$SYNC"
grep -Fq 'NIKKI_SUBSCRIPTION_STATUS_FILE' "$SYNC"
grep -Fq 'last_attempt_epoch' "$SYNC"
grep -Fq 'last_success_epoch' "$SYNC"
grep -Fq '10 4 * * *' "$CRON"
grep -Fq 'ACTION:-' "$HOTPLUG"
grep -Fq 'INTERFACE:-' "$HOTPLUG"
for path in '99-nikki-subscription-cron' 'nikki-subscription-sync' '99-nikki-subscription'; do
  grep -Fq "$path" "$WORKFLOW" || { echo "workflow does not install $path"; exit 1; }
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
NIKKI_SUBSCRIPTION_URL='https://example.invalid/sub?token=test' \
  "$INJECTOR" "$WORK_DIR/files" >"$WORK_DIR/injector.log"
DEFAULTS="$WORK_DIR/files/etc/uci-defaults/98-nikki-subscription"
[ -x "$DEFAULTS" ] || { echo "subscription defaults is not executable"; exit 1; }
grep -Fq 'nikki.subscription.url' "$DEFAULTS"
grep -Fq 'nikki.subscription.prefer=local' "$DEFAULTS"
grep -Fq 'nikki.config.profile=subscription:subscription' "$DEFAULTS"
grep -Fq 'nikki.config.enabled=0' "$DEFAULTS"
grep -Fq '/etc/init.d/nikki-subscription-sync start' "$DEFAULTS"
grep -Fq 'nikki-subscription-url' "$ROOT_DIR/Scripts/PrivateFirmwareGuard.sh"
if grep -Fq 'https://example.invalid/sub?token=test' "$DEFAULTS" "$WORK_DIR/injector.log"; then
  echo 'subscription URL was written or logged in plaintext'
  exit 1
fi

BIN_DIR="$WORK_DIR/bin"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/uci" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -q ] && [ "${2:-}" = get ] && [ "${3:-}" = nikki.subscription.url ]; then
  printf '%s\n' "${UCI_SUBSCRIPTION_URL:-}"
fi
exit 0
EOF
cat >"$BIN_DIR/ubus" <<'EOF'
#!/bin/sh
if [ "${WAN_UP:-1}" = 1 ]; then
  printf '%s\n' '{"up": true}'
else
  printf '%s\n' '{"up": false}'
fi
EOF
cat >"$BIN_DIR/ip" <<'EOF'
#!/bin/sh
if [ "${1:-}" = route ] && [ "${2:-}" = show ] && [ "${3:-}" = default ] && [ "${WAN_ROUTE:-1}" = 1 ]; then
  printf '%s\n' 'default via 192.0.2.1 dev wan'
fi
EOF
cat >"$BIN_DIR/service" <<'EOF'
#!/bin/sh
exit "${NIKKI_SERVICE_RC:-0}"
EOF
cat >"$BIN_DIR/nikki-init" <<'EOF'
#!/bin/sh
printf '%s\n' "${1:-}" >>"${NIKKI_INIT_LOG:?}"
EOF
chmod 0755 "$BIN_DIR"/*

SYNC_CONFIG="$WORK_DIR/nikki"
SYNC_STATUS="$WORK_DIR/subscription.status"
SYNC_LOCK="$WORK_DIR/subscription.lock"
SYNC_INIT_LOG="$WORK_DIR/nikki-init.log"

# A firmware without an injected subscription is healthy and records no URL.
rm -f "$SYNC_CONFIG" "$SYNC_STATUS"
PATH="$BIN_DIR:$PATH" \
  NIKKI_SUBSCRIPTION_NIKKI_CONFIG="$SYNC_CONFIG" \
  NIKKI_SUBSCRIPTION_STATUS_FILE="$SYNC_STATUS" \
  NIKKI_SUBSCRIPTION_LOCK_DIR="$SYNC_LOCK" \
  "$SYNC"
grep -Fxq 'configured=0' "$SYNC_STATUS"
grep -Fxq 'last_result=unconfigured' "$SYNC_STATUS"

touch "$SYNC_CONFIG"
PATH="$BIN_DIR:$PATH" \
  UCI_SUBSCRIPTION_URL='https://secret.example/subscription?token=do-not-leak' \
  NIKKI_SUBSCRIPTION_NIKKI_CONFIG="$SYNC_CONFIG" \
  NIKKI_SUBSCRIPTION_NIKKI_INIT="$BIN_DIR/nikki-init" \
  NIKKI_SUBSCRIPTION_STATUS_FILE="$SYNC_STATUS" \
  NIKKI_SUBSCRIPTION_LOCK_DIR="$SYNC_LOCK" \
  NIKKI_INIT_LOG="$SYNC_INIT_LOG" \
  "$SYNC"
grep -Fxq 'configured=1' "$SYNC_STATUS"
grep -Fxq 'last_result=success' "$SYNC_STATUS"
grep -Eq '^last_attempt_epoch=[0-9]+$' "$SYNC_STATUS"
grep -Eq '^last_success_epoch=[0-9]+$' "$SYNC_STATUS"
grep -Fxq 'restart' "$SYNC_INIT_LOG"
if grep -Fq 'https://secret.example/subscription?token=do-not-leak' "$SYNC_STATUS"; then
  echo 'subscription status leaked the URL'
  exit 1
fi

rm -f "$SYNC_LOCK"
if PATH="$BIN_DIR:$PATH" \
  NIKKI_SERVICE_RC=1 \
  UCI_SUBSCRIPTION_URL='https://secret.example/subscription?token=do-not-leak' \
  NIKKI_SUBSCRIPTION_NIKKI_CONFIG="$SYNC_CONFIG" \
  NIKKI_SUBSCRIPTION_NIKKI_INIT="$BIN_DIR/nikki-init" \
  NIKKI_SUBSCRIPTION_STATUS_FILE="$SYNC_STATUS" \
  NIKKI_SUBSCRIPTION_LOCK_DIR="$SYNC_LOCK" \
  NIKKI_INIT_LOG="$SYNC_INIT_LOG" \
  "$SYNC"; then
  echo 'failed subscription update unexpectedly succeeded'
  exit 1
fi
grep -Fxq 'last_result=failed' "$SYNC_STATUS"

rm -f "$SYNC_LOCK"
PATH="$BIN_DIR:$PATH" \
  WAN_UP=0 \
  NIKKI_SUBSCRIPTION_MAX_ATTEMPTS=0 \
  UCI_SUBSCRIPTION_URL='https://secret.example/subscription?token=do-not-leak' \
  NIKKI_SUBSCRIPTION_NIKKI_CONFIG="$SYNC_CONFIG" \
  NIKKI_SUBSCRIPTION_NIKKI_INIT="$BIN_DIR/nikki-init" \
  NIKKI_SUBSCRIPTION_STATUS_FILE="$SYNC_STATUS" \
  NIKKI_SUBSCRIPTION_LOCK_DIR="$SYNC_LOCK" \
  NIKKI_INIT_LOG="$SYNC_INIT_LOG" \
  "$SYNC"
grep -Fxq 'last_result=deferred-wan' "$SYNC_STATUS"

echo 'nikki subscription sync test passed'
