#!/usr/bin/env bash
# CI Debug Gate - Tailscale setup (GitHub Actions runner)
# Requires env: HEADSCALE_AUTHKEY (hskey-auth-...), HEADSCALE_LOGIN (https://...)
# Outputs env file entries: CI_TAILNET_IP, CI_TAILNET_OCTET
# Idempotent-ish: re-runs just re-up; on failure returns nonzero so the
# debug gate can degrade gracefully.
set -uo pipefail

: "${HEADSCALE_AUTHKEY:?HEADSCALE_AUTHKEY is required}"
: "${HEADSCALE_LOGIN:?HEADSCALE_LOGIN is required}"

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
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else SUDO=""; fi
  $SUDO dpkg -i "$RUNNER_TEMP/tailscale.deb" || $SUDO apt -f -yqq install
fi

tailscale version | head -n1

# Start tailscaled manually (no systemd on hosted runners)
$SUDO tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 --state=/run/tailscaled-tmp.state >/tmp/tailscaled.log 2>&1 &
TS_PID=$!
echo "tailscaled pid=$TS_PID"
sleep 2
if ! kill -0 "$TS_PID" 2>/dev/null; then
  echo "ERROR: tailscaled exited immediately; last log lines:"
  tail -n 30 /tmp/tailscaled.log 2>/dev/null || true
  exit 1
fi

# Register as an ephemeral node; hostname doubles as MagicDNS label
HOSTNAME_LABEL="ci-debug-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
if ! tailscale up \
    --login-server="$HEADSCALE_LOGIN" \
    --authkey="$HEADSCALE_AUTHKEY" \
    --hostname="$HOSTNAME_LABEL" \
    --advertise-tags=tag:ci-debug \
    --ssh \
    --ephemeral \
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
