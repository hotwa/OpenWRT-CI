#!/usr/bin/env bash
# CI Debug Gate - Tailscale setup (GitHub Actions runner)
# Requires env: HEADSCALE_AUTHKEY (hskey-auth-...), HEADSCALE_LOGIN (https://...)
# Outputs env file entries: CI_TAILNET_IP, CI_TAILNET_OCTET,
# CI_TSCALE_HOSTNAME (the full MagicDNS name) and CI_TSCALE_DNS_NAME.
# If CI_DEBUG_ENV_FILE is set, it receives shell-safe assignments for the
# current caller to source. GITHUB_ENV remains populated for later steps.
# Idempotent-ish: re-runs just re-up; on failure returns nonzero so the
# debug gate can degrade gracefully.
set -uo pipefail

: "${HEADSCALE_AUTHKEY:?HEADSCALE_AUTHKEY is required}"
: "${HEADSCALE_LOGIN:?HEADSCALE_LOGIN is required}"

# Keep this initialized even when tailscale is already installed. Hosted
# runners may be reused, and set -u must not depend on the install branch.
if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else SUDO=""; fi
CI_DEBUG_ENV_FILE="${CI_DEBUG_ENV_FILE:-${RUNNER_TEMP:-/tmp}/ci-debug-env}"

if ! command -v tailscale >/dev/null 2>&1; then
  # NOTE: do NOT use https://tailscale.com/install.sh here. This CI's hermes
  # step copies an Alpine musl minirootfs into system /lib (build_hermes_core.sh),
  # which makes install.sh misdetect the Ubuntu runner as Alpine and fail with
  # "requires the community repo". Download the Ubuntu deb explicitly instead.
  echo "Installing tailscale client (Ubuntu amd64 deb)"
  DEB_URL=""
  for v in 1.94.2 1.92.0 1.90.0; do
    if curl -fsS -o /dev/null -I "https://pkgs.tailscale.com/stable/tailscale_${v}_amd64.deb"; then
      DEB_URL="https://pkgs.tailscale.com/stable/tailscale_${v}_amd64.deb"
      break
    fi
  done
  [ -n "$DEB_URL" ] || { echo "ERROR: no tailscale deb available"; exit 1; }
  curl -fsSL "$DEB_URL" -o "$RUNNER_TEMP/tailscale.deb"
  [ -s "$RUNNER_TEMP/tailscale.deb" ] || { echo "ERROR: tailscale deb download empty"; exit 1; }
  $SUDO dpkg -i "$RUNNER_TEMP/tailscale.deb" || $SUDO apt -f -yqq install
fi

tailscale version | head -n1

# The deb postinst auto-starts a systemd-managed tailscaled on hosted runners,
# which holds /var/run/tailscale/tailscaled.sock and makes our manual
# userspace-networking instance die with "address already in use".
$SUDO systemctl stop tailscaled 2>/dev/null || true
$SUDO systemctl disable tailscaled 2>/dev/null || true
for _ in 1 2 3 4 5; do
  [ -S /var/run/tailscale/tailscaled.sock ] || break
  sleep 1
done

# Start tailscaled manually (userspace TUN; hosted runners have no TUN device)
$SUDO tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 --state=/run/tailscaled-tmp.state >/tmp/tailscaled.log 2>&1 &
TS_PID=$!
echo "tailscaled pid=$TS_PID"
sleep 2
if ! kill -0 "$TS_PID" 2>/dev/null; then
  echo "ERROR: tailscaled exited immediately; last log lines:"
  tail -n 30 /tmp/tailscaled.log 2>/dev/null || true
  exit 1
fi

# Register a short-lived debug node. The Headscale preauth key owns the
# tag:ci-debug and ephemeral properties; do not redundantly request a tag
# here, because the control plane may reject a client-requested tag even when
# the key itself is already scoped to it. Tailscale 1.94.2 also has no
# documented `tailscale up --ephemeral` flag.
HOSTNAME_LABEL="ci-debug-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
if ! $SUDO tailscale up \
    --login-server="$HEADSCALE_LOGIN" \
    --auth-key="$HEADSCALE_AUTHKEY" \
    --hostname="$HOSTNAME_LABEL" \
    --ssh \
    --accept-routes=false \
    --accept-dns=false \
    --timeout=120s; then
  echo "ERROR: tailscale up failed; last log lines:"
  tail -n 30 /tmp/tailscaled.log
  kill "$TS_PID" 2>/dev/null || true
  exit 1
fi

TS_IP="$($SUDO tailscale ip -4)"
if [ -z "$TS_IP" ]; then
  echo "ERROR: no tailnet IPv4 assigned"
  kill "$TS_PID" 2>/dev/null || true
  exit 1
fi
TS_OCTET="${TS_IP##*.}"
TS_DNS_NAME="$($SUDO tailscale status --json 2>/dev/null \
  | sed -n 's/^[[:space:]]*"DNSName": "\([^"]*\)".*/\1/p' \
  | head -n 1)"
TS_DNS_NAME="${TS_DNS_NAME%.}"
[ -n "$TS_DNS_NAME" ] || TS_DNS_NAME="$HOSTNAME_LABEL"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    printf 'CI_TAILNET_IP=%s\n' "$TS_IP"
    printf 'CI_TAILNET_OCTET=%s\n' "$TS_OCTET"
    printf 'CI_TSCALE_PID=%s\n' "$TS_PID"
    printf 'CI_TSCALE_HOSTNAME=%s\n' "$TS_DNS_NAME"
    printf 'CI_TSCALE_DNS_NAME=%s\n' "$TS_DNS_NAME"
  } >> "$GITHUB_ENV"
fi

# GITHUB_ENV is intentionally not used for same-step communication: GitHub
# exposes it only to subsequent steps. `%q` makes these assignments safe to
# source in the current bash process.
mkdir -p "$(dirname "$CI_DEBUG_ENV_FILE")"
{
  printf 'CI_TAILNET_IP=%q\n' "$TS_IP"
  printf 'CI_TAILNET_OCTET=%q\n' "$TS_OCTET"
  printf 'CI_TSCALE_PID=%q\n' "$TS_PID"
  printf 'CI_TSCALE_HOSTNAME=%q\n' "$TS_DNS_NAME"
  printf 'CI_TSCALE_DNS_NAME=%q\n' "$TS_DNS_NAME"
} > "$CI_DEBUG_ENV_FILE"

echo "Enrolled: $HOSTNAME_LABEL / $TS_IP (ssh user: runner)"
echo "MagicDNS FQDN: $TS_DNS_NAME"
echo "DERP/netcheck evidence:"
$SUDO timeout 30 tailscale netcheck 2>&1 | sed -n '1,25p' || true
