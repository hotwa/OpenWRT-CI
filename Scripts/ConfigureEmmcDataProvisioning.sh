#!/bin/sh
# Configure the deliberately opt-in first-boot eMMC data provisioner.
#
# The provisioner itself carries the device and topology checks. Keeping the
# opt-in in the caller workflow makes a first-device rollout observable before
# another hardware layout is allowed to write its GPT.

set -eu

if [ "$#" -ne 2 ]; then
	echo "usage: $0 <files-overlay-dir> <true|false>" >&2
	exit 1
fi

FILES_DIR="$1"
ENABLED="$2"
CONFIG_FILE="$FILES_DIR/etc/config/agent-storage"

case "$ENABLED" in
	true|false) ;;
	*)
		echo "ERROR: eMMC data provisioning input must be true or false, got: $ENABLED" >&2
		exit 1
		;;
esac

[ -d "$FILES_DIR" ] || {
	echo "ERROR: files overlay directory does not exist: $FILES_DIR" >&2
	exit 1
}

mkdir -p "$(dirname "$CONFIG_FILE")"
if [ ! -f "$CONFIG_FILE" ]; then
	cat >"$CONFIG_FILE" <<'EOF'
config emmc_data 'main'
	option enabled '0'
	option min_size_mb '1024'
	option label 'openwrt-data'
EOF
fi

value=0
[ "$ENABLED" = true ] && value=1

if grep -q '^[[:space:]]*option enabled ' "$CONFIG_FILE"; then
	sed -i "s#^[[:space:]]*option enabled .*#\toption enabled '$value'#" "$CONFIG_FILE"
else
	printf "\toption enabled '%s'\n" "$value" >>"$CONFIG_FILE"
fi

exit 0
