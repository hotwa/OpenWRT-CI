#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "usage: $0 <files-overlay-dir> <true|false>" >&2
	exit 1
fi

FILES_DIR="$1"
ENABLE="$2"
BOOTSTRAP="$FILES_DIR/etc/uci-defaults/92-cpe-5g-network"

case "$ENABLE" in
	true|false) ;;
	*)
		echo "ERROR: CPE-5G network input must be true or false, got: $ENABLE" >&2
		exit 1
		;;
esac

[ -d "$FILES_DIR" ] || {
	echo "ERROR: files overlay directory does not exist: $FILES_DIR" >&2
	exit 1
}

[ "$ENABLE" = true ] || exit 0

mkdir -p "$(dirname "$BOOTSTRAP")"
cat >"$BOOTSTRAP" <<'EOF'
#!/bin/sh
set -eu

uci set network.5G='interface'
uci set network.5G.proto='dhcp'
uci set network.5G.device='usb0'
uci set network.5G.defaultroute='0'

wan_zone=''
for section in $(uci show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
	if [ "$(uci -q get "firewall.$section.name" || true)" = 'wan' ]; then
		wan_zone="$section"
		break
	fi
done

[ -n "$wan_zone" ] || {
	echo 'ERROR: CPE-5G bootstrap could not find the wan firewall zone' >&2
	exit 1
}

case " $(uci -q get "firewall.$wan_zone.network" || true) " in
	*' 5G '*) ;;
	*) uci add_list firewall.$wan_zone.network='5G' ;;
esac

forwarding=''
for section in $(uci show firewall | sed -n 's/^firewall\.\([^.=]*\)=forwarding$/\1/p'); do
	if [ "$(uci -q get "firewall.$section.src" || true)" = 'lan' ] &&
	   [ "$(uci -q get "firewall.$section.dest" || true)" = 'wan' ]; then
		forwarding="$section"
		break
	fi
done

if [ -z "$forwarding" ]; then
	forwarding="$(uci add firewall forwarding)"
	uci set firewall.$forwarding.src='lan'
	uci set firewall.$forwarding.dest='wan'
fi

uci commit network
uci commit firewall
exit 0
EOF
chmod 755 "$BOOTSTRAP"

echo "CPE-5G network bootstrap: enabled for usb0 without a default route"
