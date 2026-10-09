#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pi_shim="$root/files/usr/sbin/multica-pi-cli"
oc_shim="$root/files/usr/sbin/multica-opencode-cli"
sh -n "$pi_shim"
sh -n "$oc_shim"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/opencode/1.18.35/bin"
printf '%s\n' '{"components":{"@earendil-works/pi-coding-agent":"1.0.4"}}' >"$work/manifest.json"
cat >"$work/bin/jsonfilter" <<'EOF'
#!/bin/sh
printf '1.0.4\n'
EOF
cat >"$work/bin/real-pi" <<'EOF'
#!/bin/sh
printf 'real-pi:%s\n' "$*"
EOF
cat >"$work/bin/real-oc" <<'EOF'
#!/bin/sh
printf 'real-oc:%s\n' "$*"
EOF
chmod +x "$work/bin"/*
touch "$work/opencode/1.18.35/bin/opencode"
chmod +x "$work/opencode/1.18.35/bin/opencode"
ln -s 1.18.35 "$work/opencode/current"
export PATH="$work/bin:$PATH"
export MULTICA_PI_REAL_BIN="$work/bin/real-pi" MULTICA_PI_MANIFEST="$work/manifest.json"
export MULTICA_OPENCODE_REAL_BIN="$work/bin/real-oc" MULTICA_OPENCODE_CURRENT="$work/opencode/current"
[ "$(sh "$pi_shim" --version)" = 1.0.4 ]
[ "$(sh "$pi_shim" --print custom)" = 'real-pi:--print custom' ]
[ "$(sh "$oc_shim" --version)" = 1.18.35 ]
[ "$(sh "$oc_shim" --print custom)" = 'real-oc:--print custom' ]
MULTICA_PI_MANIFEST="$work/missing" \
  sh "$pi_shim" --version | grep -Fxq 'real-pi:--version'
MULTICA_OPENCODE_CURRENT="$work/missing" \
  sh "$oc_shim" --version | grep -Fxq 'real-oc:--version'
grep -Fq 'MULTICA_PI_PATH=/usr/sbin/multica-pi-cli' "$root/files/etc/init.d/multica"
grep -Fq 'MULTICA_OPENCODE_PATH=/usr/sbin/multica-opencode-cli' "$root/files/etc/init.d/multica"
echo 'Multica CLI version shims passed'
