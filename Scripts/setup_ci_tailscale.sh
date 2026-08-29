#!/usr/bin/env bash
# CI Debug Gate - Tailscale setup (GitHub Actions runner)
# Requires env: HEADSCALE_AUTHKEY (hskey-auth-...), HEADSCALE_LOGIN (https://...)
# Outputs env file entries: CI_TAILNET_IP, CI_TAILNET_OCTET
# Idempotent-ish: re-runs just re-up; on failure returns nonzero so the
# debug gate can degrade gracefully.
set -uo pipefail

: "${HEADSCALE_AUTHKEY:?HEADSCALE_AUTHKEY is required}"
: "${HEADSCALE_LOGIN:?HEADSCALE_LOGIN is required}"

TS_INSTALL="https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION:-1.86.5}_amd64.deb"
# 2026-08: 1.86.5 is a conservative stable floor; bump after the derper
# (v1.98.8) compatibility review if a newer client is wanted.

if ! command -v tailscale >/dev/null 2>&1; then
  echo "Installing tailscale client ($TS_INSTALL)"
  curl -fsSL "$TS_INSTALL" -o "$RUNNER_TEMP/tailscale.deb"
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else SUDO=""; fi
  $SUDO apt -yqq install ca-certificates gnupg >/dev/null
  $SUDO dpkg -i "$RUNNER_TEMP/tailscale.deb" || $SUDO apt -f -yqq install
fi

tailscale version | head -n1

# Start tailscaled manually (no systemd on hosted runners)
$SUDO tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 --state=/run/tailscaled-tmp.state >/tmp/tailscaled.log 2>&1 &
TS_PID=$!
echo "tailscaled pid=$TS_PID"

# Register as an ephemeral node; hostname doubles as MagicDNS label
HOSTNAME_LABEL="ci-debug-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
if ! tailscale up \
    --login-server="$HEADSCALE_LOGIN" \
    --authkey="$HEADSCALE_AUTHKEY" \
    --hostname="$HOSTNAME_LABEL" \
    --advertise-tags=tag:ci-debug \
    --ssh \
    --accept-routes=false \
    --accept-dns=false \
    --timeout=120s; then
  echo "ERROR: tailscale up failed; last log lines:"
  tail -n 30 /tmp/tailscaled.log
  kill "$TS_PID" 2>/dev/null || true
  exit 1
fi

TS_IP="$(tailscale ip -4)"
if [ -z "$TS_IP" ]; then
  echo "ERROR: no tailnet IPv4 assigned"
  kill "$TS_PID" 2>/dev/null || true
  exit 1
fi
TS_OCTET="${TS_IP##*.}"

{
  echo "CI_TAILNET_IP=$TS_IP"
  echo "CI_TAILNET_OCTET=$TS_OCTET"
  echo "CI_TSCALE_PID=$TS_PID"
  echo "CI_TSCALE_HOSTNAME=$HOSTNAME_LABEL"
} >> "$GITHUB_ENV"

echo "Enrolled: $HOSTNAME_LABEL / $TS_IP (ssh user: runner)"
echo "DERP/netcheck evidence:"
timeout 30 tailscale netcheck 2>&1 | sed -n '1,25p' || true
