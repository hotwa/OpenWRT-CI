#!/bin/bash
set -euo pipefail

TARGET_FILES="${1:-${GITHUB_WORKSPACE:-$(pwd)}/wrt/files}"
CONFIG_FILE="$TARGET_FILES/etc/config/wrtbak"
DEFAULTS_FILE="$TARGET_FILES/etc/uci-defaults/91-wrtbak-r2-defaults"

R2_ENDPOINT="${WRTBAK_R2_ENDPOINT:-https://a15eff50866373c517f961928c24c54a.r2.cloudflarestorage.com}"
R2_REGION="${WRTBAK_R2_REGION:-auto}"
R2_BUCKET="${WRTBAK_R2_BUCKET:-knowledge}"
R2_PREFIX="${WRTBAK_R2_PREFIX:-openwrt-config-backup/wrtbak}"
R2_ACCESS_KEY_ID="${WRTBAK_R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${WRTBAK_R2_SECRET_ACCESS_KEY:-}"
R2_FORCE_PATH_STYLE="${WRTBAK_R2_FORCE_PATH_STYLE:-1}"
DEVICE_ALIAS="${WRTBAK_DEVICE_ALIAS:-}"
PROXY_PROFILE="${WRTBAK_PROXY_PROFILE:-}"
PROXY_URL="${WRTBAK_PROXY_URL:-}"

has_newline_or_quote() {
	case "$1" in
		*$'\n'*|*$'\r'*|*"'"*)
			return 0
			;;
	esac
	return 1
}

require_uci_safe() {
	local name="$1"
	local value="$2"

	if has_newline_or_quote "$value"; then
		echo "wrtbak R2 config: $name contains unsupported newline or single quote" >&2
		exit 1
	fi
}

normalize_path() {
	local value="$1"

	while [ "${value#/}" != "$value" ]; do
		value="${value#/}"
	done
	while [ "${value%/}" != "$value" ]; do
		value="${value%/}"
	done

	if [ -n "$value" ]; then
		printf '/%s\n' "$value"
	else
		printf '/\n'
	fi
}

site_proxy_profile() {
	case "${WRT_IP:-}" in
		192.168.10.*) printf 'home\n' ;;
		192.168.11.*) printf 'office\n' ;;
		192.168.12.*) printf 'dorm\n' ;;
		*) printf '\n' ;;
	esac
}

resolve_proxy_url() {
	local profile="$1"

	if [ -n "$PROXY_URL" ]; then
		printf '%s\n' "$PROXY_URL"
		return 0
	fi

	if [ -z "$profile" ] || [ "$profile" = "auto" ]; then
		profile="$(site_proxy_profile)"
	fi

	case "$profile" in
		home) printf '%s\n' "${WRTBAK_HOME_PROXY_URL:-}" ;;
		office) printf '%s\n' "${WRTBAK_OFFICE_PROXY_URL:-}" ;;
		dorm) printf '%s\n' "${WRTBAK_DORM_PROXY_URL:-}" ;;
		"") printf '\n' ;;
		*)
			echo "wrtbak R2 config: unknown WRTBAK_PROXY_PROFILE '$profile'" >&2
			exit 1
			;;
	esac
}

case "${R2_ACCESS_KEY_ID:+set}:${R2_SECRET_ACCESS_KEY:+set}" in
	:)
		echo "wrtbak R2 config: credentials are empty; leaving remote target disabled"
		exit 0
		;;
	set:set)
		;;
	*)
		echo "wrtbak R2 config: access key and secret key must be provided together" >&2
		exit 1
		;;
esac

require_uci_safe endpoint "$R2_ENDPOINT"
require_uci_safe region "$R2_REGION"
require_uci_safe bucket "$R2_BUCKET"
require_uci_safe prefix "$R2_PREFIX"
require_uci_safe access_key "$R2_ACCESS_KEY_ID"
require_uci_safe secret_key "$R2_SECRET_ACCESS_KEY"
require_uci_safe device_alias "$DEVICE_ALIAS"

PROXY_URL="$(resolve_proxy_url "$PROXY_PROFILE")"
require_uci_safe proxy_url "$PROXY_URL"
R2_PREFIX="$(normalize_path "$R2_PREFIX")"

mkdir -p "$(dirname "$CONFIG_FILE")"
umask 077

cat >"$CONFIG_FILE" <<EOF
config wrtbak 'main'
	option enabled '1'
	option max_upload_mb '32'
	option output_dir '/tmp/wrtbak'
	option rollback_dir '/overlay/wrtbak/rollback'
	option default_mode 'review-required'
	option default_target 's3'
	option device_alias '$DEVICE_ALIAS'
	option proxy_url '$PROXY_URL'
	option history_file '/overlay/wrtbak/remote-history.jsonl'
	option history_max_entries '20'
	option keep_local_after_upload '0'

config remote 'webdav'
	option enabled '0'
	option driver 'curl'
	option url ''
	option username ''
	option password ''
	option path '/'

config remote 's3'
	option enabled '1'
	option driver 'rclone'
	option endpoint '$R2_ENDPOINT'
	option region '$R2_REGION'
	option bucket '$R2_BUCKET'
	option access_key '$R2_ACCESS_KEY_ID'
	option secret_key '$R2_SECRET_ACCESS_KEY'
	option path '$R2_PREFIX'
	option force_path_style '$R2_FORCE_PATH_STYLE'

config schedule 'auto'
	option enabled '0'
	option frequency 'daily'
	option time '03:30'
	option weekday '0'
	option day_of_month '1'
	option profile 'auto'
	option items 'all'
	option format 'wrtbak'
	option max_backups '0'
	option target 's3'
EOF

chmod 600 "$CONFIG_FILE" 2>/dev/null || true

mkdir -p "$(dirname "$DEFAULTS_FILE")"
cat >"$DEFAULTS_FILE" <<EOF
#!/bin/sh
set -eu

changed=0
uci -q get wrtbak.main >/dev/null || {
	uci set wrtbak.main='wrtbak'
	changed=1
}

if ! uci -q get wrtbak.main.site >/dev/null; then
	uci set wrtbak.main.site='$SITE_NAME'
	changed=1
fi

if ! uci -q get wrtbak.main.proxy_artifacts_enabled >/dev/null; then
	uci set wrtbak.main.proxy_artifacts_enabled='$PROXY_ARTIFACTS_ENABLED'
	changed=1
fi

if ! uci -q get wrtbak.main.proxy_update_mode >/dev/null; then
	uci set wrtbak.main.proxy_update_mode='$PROXY_UPDATE_MODE'
	changed=1
fi

if ! uci -q get wrtbak.main.proxy_url >/dev/null; then
	uci set wrtbak.main.proxy_url='$PROXY_URL'
	changed=1
fi

if [ "\$changed" = "1" ]; then
	uci commit wrtbak
fi

exit 0
EOF
chmod 755 "$DEFAULTS_FILE" 2>/dev/null || true

if [ -n "$PROXY_URL" ]; then
	proxy_status=present
else
	proxy_status=empty
fi

echo "wrtbak R2 config: enabled endpoint=$R2_ENDPOINT bucket=$R2_BUCKET prefix=$R2_PREFIX alias=${DEVICE_ALIAS:-unset} proxy=$proxy_status"
