#!/bin/bash
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
URL="${NIKKI_SUBSCRIPTION_URL:-}"
DEFAULTS="$TARGET_FILES/etc/uci-defaults/98-nikki-subscription"

[ -n "$URL" ] || exit 0
case "$URL" in
  *$'\n'*|*$'\r'*) echo 'Nikki subscription URL must not contain a newline' >&2; exit 1 ;;
esac

URL_B64="$(printf '%s' "$URL" | base64 | tr -d '\n')"
mkdir -p "$(dirname "$DEFAULTS")"
umask 077
cat >"$DEFAULTS" <<EOF2
#!/bin/sh
set -eu

nikki_config="\${NIKKI_SUBSCRIPTION_NIKKI_CONFIG:-/etc/config/nikki}"
[ -f "\$nikki_config" ] || exit 0
url="\$(printf '%s' '$URL_B64' | base64 -d)"
[ -n "\$url" ] || exit 1
uci set "nikki.subscription.url=\$url"
uci set 'nikki.subscription.prefer=local'
uci set 'nikki.config.profile=subscription:subscription'
uci set 'nikki.config.enabled=0'
uci commit nikki
sync_init="\${NIKKI_SUBSCRIPTION_SYNC_INIT:-/etc/init.d/nikki-subscription-sync}"
[ -x "\$sync_init" ] && "\$sync_init" enable
[ -x "\$sync_init" ] && "\$sync_init" start >/dev/null 2>&1 || true
exit 0
EOF2
chmod 700 "$DEFAULTS"
printf '%s\n' 'nikki subscription configuration injected'
