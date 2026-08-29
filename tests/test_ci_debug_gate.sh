#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT_DIR/Scripts/setup_ci_tailscale.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

[ -f "$SETUP" ] || { echo "missing CI Tailscale setup script"; exit 1; }
WORKFLOW="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

# The workflow invokes this script directly in some historical revisions, so
# keep the executable bit in Git as well as the defensive `bash` invocation.
[ "$(git -C "$ROOT_DIR" ls-files -s -- Scripts/setup_ci_tailscale.sh | awk '{print $1}')" = "100755" ] || {
  echo "CI Tailscale setup script must be executable in Git"
  exit 1
}
grep -q 'bash "\$GITHUB_WORKSPACE/Scripts/setup_ci_tailscale.sh"' "$WORKFLOW" || {
  echo "workflow must invoke the setup script through bash"
  exit 1
}

# Static guards catch regressions without touching the network or secrets.
if grep -Eq '^[[:space:]]+--ephemeral([[:space:]]|\\|)' "$SETUP"; then
  echo "tailscale setup must not pass unsupported --ephemeral"
  exit 1
fi
if grep -Eq '^[[:space:]]+--advertise-tags=' "$SETUP"; then
  echo "tailscale setup must let the preauth key assign its tag"
  exit 1
fi
grep -q -- '--auth-key="\$HEADSCALE_AUTHKEY"' "$SETUP" || {
  echo "tailscale setup must use documented --auth-key"
  exit 1
}
grep -q 'SUDO="sudo -E"' "$SETUP" || {
  echo "SUDO must be initialized outside the install branch"
  exit 1
}
grep -q 'source "\$DEBUG_ENV_FILE"' "$WORKFLOW" || {
  echo "workflow must source same-step debug environment"
  exit 1
}

# Mock the already-installed-client path. This exercises the former set -u
# failure where SUDO was assigned only during installation.
MOCK_BIN="$WORK_DIR/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/sudo" <<'EOF'
#!/bin/bash
set -e
[ "${1:-}" = "-E" ] && shift
exec "$@"
EOF
cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$MOCK_BIN/tailscale" <<'EOF'
#!/bin/bash
case "${1:-}" in
  version) echo '1.94.2';;
  up) printf '%s\n' "$*" > "${MOCK_TAILSCALE_UP_ARGS:?}";;
  ip) echo '100.64.0.42';;
  status) printf '%s\n' '{' '  "Self": {' '    "DNSName": "ci-debug-test.hs.jmsu.top."' '  }' '}';;
  netcheck) echo 'mock netcheck';;
  *) exit 0;;
esac
EOF
cat > "$MOCK_BIN/tailscaled" <<'EOF'
#!/bin/bash
while :; do sleep 1; done
EOF
chmod +x "$MOCK_BIN"/*

export PATH="$MOCK_BIN:$PATH"
export HEADSCALE_AUTHKEY='hskey-auth-''mock'
export HEADSCALE_LOGIN='https://headscale.invalid'
export RUNNER_TEMP="$WORK_DIR/temp"
export GITHUB_ENV="$WORK_DIR/github-env"
export CI_DEBUG_ENV_FILE="$WORK_DIR/current-step.env"
export MOCK_TAILSCALE_UP_ARGS="$WORK_DIR/up-args"
mkdir -p "$RUNNER_TEMP"

bash "$SETUP" > "$WORK_DIR/setup.log"

grep -q -- '--auth-key=hskey-auth-''mock' "$MOCK_TAILSCALE_UP_ARGS" || {
  echo "mock tailscale up did not receive --auth-key"
  exit 1
}
if grep -q -- '--ephemeral' "$MOCK_TAILSCALE_UP_ARGS"; then
  echo "mock tailscale up received unsupported --ephemeral"
  exit 1
fi
if grep -q -- '--advertise-tags=' "$MOCK_TAILSCALE_UP_ARGS"; then
  echo "mock tailscale up redundantly requested a tag"
  exit 1
fi
grep -q '^CI_TAILNET_IP=100\.64\.0\.42$' "$GITHUB_ENV" || {
  echo "GITHUB_ENV output missing tailnet IP"
  exit 1
}
grep -q '^CI_TSCALE_DNS_NAME=ci-debug-test\.hs\.jmsu\.top$' "$GITHUB_ENV" || {
  echo "GITHUB_ENV output missing full MagicDNS name"
  exit 1
}
# Verify the explicit same-step file is sourceable and carries the values.
# shellcheck disable=SC1090
source "$CI_DEBUG_ENV_FILE"
[ "$CI_TAILNET_IP" = '100.64.0.42' ] || exit 1
[ "$CI_TAILNET_OCTET" = '42' ] || exit 1
[ "$CI_TSCALE_DNS_NAME" = 'ci-debug-test.hs.jmsu.top' ] || exit 1

kill "$CI_TSCALE_PID" 2>/dev/null || true
echo "CI debug gate test passed"
