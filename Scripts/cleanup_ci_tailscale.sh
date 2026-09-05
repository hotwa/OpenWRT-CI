#!/usr/bin/env bash
# Best-effort local teardown for the CI debug Tailnet client. `logout` revokes
# this runner's local node key; server-side deletion/reaping remains controlled
# by the Headscale ephemeral-key policy.
set -uo pipefail

if command -v sudo >/dev/null 2>&1; then SUDO="sudo -E"; else SUDO=""; fi

if command -v tailscale >/dev/null 2>&1; then
  $SUDO tailscale logout >/dev/null 2>&1 || true
fi

if [[ -n "${CI_TSCALE_PID:-}" ]]; then
  $SUDO kill "$CI_TSCALE_PID" 2>/dev/null || true
fi

$SUDO rm -f /run/tailscaled-tmp.state 2>/dev/null || true
