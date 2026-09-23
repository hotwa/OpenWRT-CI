#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEALTH="$ROOT_DIR/files/usr/sbin/openwrt-ci-health"

[ -x "$HEALTH" ] || { echo "missing executable health endpoint" >&2; exit 1; }
sh -n "$HEALTH"
grep -Fq '100.100.100.100' "$HEALTH"
grep -Fq 'tailscale status --json' "$HEALTH"
grep -Fq 'nslookup "$SELF_DNS_NAME" "$MAGICDNS_RESOLVER"' "$HEALTH"
grep -Fq 'nikki-dns-failopen' "$HEALTH"
grep -Fq -- '--require data,wan,tailscale,magicdns,nikki' "$HEALTH"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$BIN_DIR" "$WORK_DIR/data"

cat >"$BIN_DIR/uci" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -q ] && [ "${2:-}" = get ]; then
  case "${3:-}" in
    network.wan.proto) printf '%s\n' "${UCI_WAN_PROTO:-dhcp}" ;;
    tailscale.settings.accept_routes) printf '%s\n' "${UCI_ACCEPT_ROUTES:-1}" ;;
    nikki.config.profile) printf '%s\n' "${UCI_NIKKI_PROFILE:-subscription:subscription}" ;;
    nikki.subscription.url) printf '%s\n' "${UCI_SUBSCRIPTION_URL:-}" ;;
  esac
fi
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
case "${1:-}:${2:-}:${3:-}:${4:-}" in
  route:show:default:)
    [ "${WAN_ROUTE:-1}" = 1 ] && printf '%s\n' 'default via 192.0.2.1 dev wan'
    ;;
  link:show:dev:tailscale0) exit "${TAILSCALE_LINK_RC:-0}" ;;
esac
EOF
cat >"$BIN_DIR/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' "${TAILSCALE_STATUS_JSON:-{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"re-cs-02-s11.hs.jmsu.top.\"}}}"
EOF
cat >"$BIN_DIR/nslookup" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${1:-}" "${2:-}" >>"${NSLOOKUP_LOG:?}"
if [ "${MAGICDNS_LOOKUP_RC:-0}" = 0 ]; then
  printf '%s\n' "Name: ${1:-}"
fi
exit "${MAGICDNS_LOOKUP_RC:-0}"
EOF
cat >"$BIN_DIR/nikki-dns-failopen" <<'EOF'
#!/bin/sh
printf '%s\n' "${NIKKI_DNS_STATUS:-health=healthy(via direct)}"
EOF
cat >"$BIN_DIR/tailscale-route-reconcile" <<'EOF'
#!/bin/sh
printf 'health=%s\n' "${TAILSCALE_ROUTE_HEALTH:-healthy}"
EOF
chmod 0755 "$BIN_DIR"/*

MOUNTS_FILE="$WORK_DIR/mounts"
DATA_STATUS="$WORK_DIR/data-runtime.status"
NIKKI_CONFIG="$WORK_DIR/nikki"
SUBSCRIPTION_STATUS="$WORK_DIR/nikki-subscription-sync.status"
NSLOOKUP_LOG="$WORK_DIR/nslookup.log"
touch "$NIKKI_CONFIG"
printf '/dev/sda1 %s ext4 rw 0 0\n' "$WORK_DIR/data" >"$MOUNTS_FILE"
printf 'state=persistent\n' >"$DATA_STATUS"

run_health() {
  PATH="$BIN_DIR:$PATH" \
    OPENWRT_CI_HEALTH_DATA_ROOT="$WORK_DIR/data" \
    OPENWRT_CI_HEALTH_MOUNTS_FILE="$MOUNTS_FILE" \
    OPENWRT_CI_HEALTH_DATA_RUNTIME_STATUS_FILE="$DATA_STATUS" \
    OPENWRT_CI_HEALTH_NIKKI_CONFIG="$NIKKI_CONFIG" \
    OPENWRT_CI_HEALTH_NIKKI_SUBSCRIPTION_STATUS_FILE="$SUBSCRIPTION_STATUS" \
    OPENWRT_CI_HEALTH_NIKKI_DNS_FAILOPEN="$BIN_DIR/nikki-dns-failopen" \
    OPENWRT_CI_HEALTH_TAILSCALE_ROUTE_RECONCILE="$BIN_DIR/tailscale-route-reconcile" \
    NSLOOKUP_LOG="$NSLOOKUP_LOG" \
    "$HEALTH" "$@"
}

# Healthy DHCP, persistent /data, a live Tailscale self-query, direct Nikki,
# and no subscription URL are all acceptable at first boot.
output="$(run_health --json --require data,wan,tailscale,magicdns,nikki)"
grep -Fq '"data":{"healthy":true,"state":"persistent","mount":"block-backed"}' <<<"$output"
grep -Fq '"protocol":"dhcp"' <<<"$output"
grep -Fq '"accept_routes":true' <<<"$output"
grep -Fq '"route_health":"healthy"' <<<"$output"
grep -Fq '"magicdns":{"healthy":true,"resolver":"100.100.100.100"' <<<"$output"
grep -Fq '"nikki":{"healthy":true,"mode":"direct"}' <<<"$output"
grep -Fq '"subscription":{"healthy":true,"configured":false,"result":"unconfigured"' <<<"$output"
grep -Fxq 're-cs-02-s11.hs.jmsu.top 100.100.100.100' "$NSLOOKUP_LOG"

output="$(UCI_WAN_PROTO=pppoe NIKKI_DNS_STATUS='health=healthy(via mihomo)' run_health --json)"
grep -Fq '"protocol":"pppoe"' <<<"$output"
grep -Fq '"nikki":{"healthy":true,"mode":"mihomo"}' <<<"$output"

printf 'configured=1\nlast_result=success\nlast_attempt_epoch=123\nlast_success_epoch=123\n' >"$SUBSCRIPTION_STATUS"
output="$(UCI_SUBSCRIPTION_URL='https://secret.example/subscription?token=must-not-appear' run_health --json)"
grep -Fq '"subscription":{"healthy":true,"configured":true,"result":"success","last_attempt_epoch":123,"last_success_epoch":123}' <<<"$output"
if grep -Fq 'https://secret.example/subscription?token=must-not-appear' <<<"$output"; then
  echo 'health JSON leaked the subscription URL' >&2
  exit 1
fi

printf 'configured=1\nlast_result=failed\nlast_attempt_epoch=124\nlast_success_epoch=123\n' >"$SUBSCRIPTION_STATUS"
output="$(UCI_SUBSCRIPTION_URL='https://secret.example/subscription?token=must-not-appear' run_health --json)"
grep -Fq '"subscription":{"healthy":false,"configured":true,"result":"failed"' <<<"$output"

printf 'configured=1\nlast_result=unchanged\nlast_attempt_epoch=125\nlast_success_epoch=125\n' >"$SUBSCRIPTION_STATUS"
output="$(UCI_SUBSCRIPTION_URL='https://secret.example/subscription?token=must-not-appear' run_health --json)"
grep -Fq '"subscription":{"healthy":true,"configured":true,"result":"unchanged"' <<<"$output"

output="$(UCI_NIKKI_PROFILE='file:final.yaml' UCI_SUBSCRIPTION_URL='https://secret.example/subscription?token=must-not-appear' run_health --json)"
grep -Fq '"subscription":{"healthy":true,"configured":false,"result":"unconfigured"' <<<"$output"

if NIKKI_DNS_STATUS='health=degraded(mihomo DNS unresponsive)' run_health --json --require nikki >/dev/null; then
  echo 'degraded Nikki unexpectedly passed a required health gate' >&2
  exit 1
fi

if TAILSCALE_ROUTE_HEALTH=degraded run_health --json --require tailscale >/dev/null; then
  echo 'degraded Tailscale route reconciliation unexpectedly passed a required health gate' >&2
  exit 1
fi

printf 'tmpfs %s tmpfs rw 0 0\n' "$WORK_DIR/data" >"$MOUNTS_FILE"
if run_health --require data >/dev/null; then
  echo 'non-block-backed /data unexpectedly passed a required health gate' >&2
  exit 1
fi

echo 'openwrt-ci-health test passed'
