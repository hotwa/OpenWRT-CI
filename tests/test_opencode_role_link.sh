#!/bin/bash
# Targeted role-link and boot repair fixtures; no real /data or /root writes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINKER="$ROOT_DIR/files/usr/sbin/opencode-role-link"
INIT="$ROOT_DIR/files/etc/init.d/opencode-runtime"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
pass() { printf 'PASS: %s\n' "$*"; }
sh -n "$LINKER"
sh -n "$INIT"
grep -Fq 'OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-/data/opencode/config/opencode}"' "$LINKER"
grep -Fq 'XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/data/opencode/config}"' "$ROOT_DIR/files/usr/bin/opencode"
grep -Fq 'OPENCODE_CONFIG_DIR="$CONFIG_DIR" /usr/sbin/opencode-role-link' "$INIT"
grep -Fq 'OPENCODE_CONFIG_DIR="$DATA_ROOT/opencode/config/opencode" OPENCODE_ROLE_CARD="$DATA_ROOT/multica/openwrt-agent.md"' "$ROOT_DIR/files/etc/uci-defaults/99-auto-mount-data"
pass 'nested default matches wrapper XDG root and startup hook passes effective directory'

export OPENCODE_CONFIG_DIR="$TMP_ROOT/explicit-app-dir"
export OPENCODE_ROLE_CARD="$TMP_ROOT/role.md"
printf 'device role\n' > "$OPENCODE_ROLE_CARD"
sh "$LINKER"
[ ! -e "$OPENCODE_CONFIG_DIR" ]
pass 'unprovisioned directory is not created'
mkdir -p "$OPENCODE_CONFIG_DIR"
OPENCODE_ROLE_CARD="$TMP_ROOT/missing-role" sh "$LINKER"
[ ! -e "$OPENCODE_CONFIG_DIR/AGENTS.md" ]
pass 'missing role is a no-op'
sh "$LINKER"
[ "$(readlink "$OPENCODE_CONFIG_DIR/AGENTS.md")" = "$OPENCODE_ROLE_CARD" ]
[ ! -e "$OPENCODE_CONFIG_DIR/opencode" ]
before="$(stat -c %i "$OPENCODE_CONFIG_DIR/AGENTS.md")"
sh "$LINKER"
[ "$(stat -c %i "$OPENCODE_CONFIG_DIR/AGENTS.md")" = "$before" ]
pass 'explicit effective-directory override links directly and is idempotent'
rm "$OPENCODE_CONFIG_DIR/AGENTS.md"
printf 'user instructions\n' > "$OPENCODE_CONFIG_DIR/AGENTS.md"
sh "$LINKER"
[ "$(cat "$OPENCODE_CONFIG_DIR/AGENTS.md")" = 'user instructions' ]
rm "$OPENCODE_CONFIG_DIR/AGENTS.md"
ln -s "$TMP_ROOT/missing-user-target" "$OPENCODE_CONFIG_DIR/AGENTS.md"
sh "$LINKER"
[ "$(readlink "$OPENCODE_CONFIG_DIR/AGENTS.md")" = "$TMP_ROOT/missing-user-target" ]
pass 'user regular instructions and unrelated dangling symlink survive'
unset OPENCODE_CONFIG_DIR

# Redirect fixed firmware paths in an isolated fixture, retaining start() logic.
FIXTURE="$TMP_ROOT/boot"
mkdir -p "$FIXTURE/etc/opencode" "$FIXTURE/usr/sbin" "$FIXTURE/data" "$FIXTURE/root/.config"
touch "$FIXTURE/etc/opencode/release-url"
sed "s|/data/|$FIXTURE/data/|g" "$LINKER" > "$FIXTURE/usr/sbin/opencode-role-link"
chmod +x "$FIXTURE/usr/sbin/opencode-role-link"
sed -e "s|/etc/opencode/|$FIXTURE/etc/opencode/|g" \
    -e "s|/usr/sbin/|$FIXTURE/usr/sbin/|g" \
    -e "s|/root/.config|$FIXTURE/root/.config|g" \
    -e "s|/data|$FIXTURE/data|g" "$INIT" > "$FIXTURE/init.sh"
logger() { :; }
. "$FIXTURE/init.sh"
start
NESTED="$FIXTURE/data/opencode/config/opencode"
COMPAT="$FIXTURE/root/.config/opencode"
[ "$(readlink "$NESTED/AGENTS.md")" = "$OPENCODE_ROLE_CARD" ]
[ "$(readlink "$COMPAT")" = "$NESTED" ]
[ ! -e "$FIXTURE/data/opencode/config/AGENTS.md" ]
start
[ "$(readlink "$COMPAT")" = "$NESTED" ]
pass 'startup creates nested role link and idempotent default-XDG compatibility link'
rm "$COMPAT"
ln -s "$FIXTURE/data/opencode/config" "$COMPAT"
start
[ "$(readlink "$COMPAT")" = "$NESTED" ]
[ ! -L "$FIXTURE/data/opencode/config/config" ]
pass 'legacy compatibility link repaired without following directory symlink'
rm "$COMPAT"
ln -s "$FIXTURE/user-config-missing" "$COMPAT"
start
[ "$(readlink "$COMPAT")" = "$FIXTURE/user-config-missing" ]
rm "$COMPAT"
mkdir "$COMPAT"
printf 'user configuration\n' > "$COMPAT/keep"
start
[ "$(cat "$COMPAT/keep")" = 'user configuration' ]
[ ! -L "$COMPAT" ]
pass 'startup preserves unrelated user symlinks and directories'
rm "$FIXTURE/etc/opencode/release-url" "$NESTED/AGENTS.md"
start
[ ! -e "$NESTED/AGENTS.md" ]
pass 'startup is a no-op without device release metadata'
printf 'All OpenCode role-link tests passed.\n'
