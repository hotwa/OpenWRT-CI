#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QCA_612="$ROOT_DIR/.github/workflows/QCA-6.12-VIKINGYFY.yml"
QCA_618="$ROOT_DIR/.github/workflows/QCA-6.18-VIKINGYFY.yml"
QCA_LIBWRT="$ROOT_DIR/.github/workflows/QCA-6.12-LiBwrt.yml"
WRT_CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"
CONFIGURER="$ROOT_DIR/Scripts/ConfigureLanTailnetGateway.sh"

for workflow in "$QCA_612" "$QCA_618" "$QCA_LIBWRT"; do
	[ -f "$workflow" ] || continue

	grep -q "LAN_TAILNET:" "$workflow" || {
		echo "$workflow missing LAN_TAILNET workflow input"
		exit 1
	}

	grep -q "description: '允许 LAN 与获授权 Tailnet 设备双向访问" "$workflow" || {
		echo "$workflow missing LAN_TAILNET safety description"
		exit 1
	}

	grep -A5 '^      LAN_TAILNET:' "$workflow" | grep -q 'default: true' || {
		echo "$workflow does not default LAN_TAILNET to true"
		exit 1
	}

	grep -q "WRT_LAN_TAILNET: \${{ github.event_name != 'workflow_dispatch' || inputs.LAN_TAILNET }}" "$workflow" || {
		echo "$workflow does not pass LAN_TAILNET into WRT-CORE"
		exit 1
	}
done

grep -q "WRT_LAN_TAILNET:" "$WRT_CORE" || {
	echo "WRT-CORE missing WRT_LAN_TAILNET input"
	exit 1
}

grep -A4 '^      WRT_LAN_TAILNET:' "$WRT_CORE" | grep -q 'default: true' || {
	echo "WRT-CORE must enable the private Mesh gateway by default"
	exit 1
}

grep -q "ConfigureLanTailnetGateway.sh" "$WRT_CORE" || {
	echo "WRT-CORE does not configure the LAN-to-tailnet gateway overlay"
	exit 1
}

[ -x "$CONFIGURER" ] || {
	echo "missing executable LAN-to-tailnet workflow configurer"
	exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/files/etc/config"
cp "$ROOT_DIR/files/etc/config/tailscale" "$WORK_DIR/files/etc/config/tailscale"

"$CONFIGURER" "$WORK_DIR/files" false
grep -q "option enabled '0'" "$WORK_DIR/files/etc/config/tailscale" || {
	echo "configurer should leave LAN-to-tailnet disabled when input is false"
	exit 1
}
grep -q "option tailnet_to_lan '0'" "$WORK_DIR/files/etc/config/tailscale" || {
	echo "configurer should disable tailnet-to-LAN when input is false"
	exit 1
}
grep -q "option mesh_schema_version '2'" "$WORK_DIR/files/etc/config/tailscale" || {
	echo "configurer should stamp the private Mesh schema version"
	exit 1
}

"$CONFIGURER" "$WORK_DIR/files" true
grep -A8 "config lan_to_tailnet 'lan_to_tailnet'" "$WORK_DIR/files/etc/config/tailscale" | grep -q "option enabled '1'" || {
	echo "configurer should enable LAN-to-tailnet when input is true"
	exit 1
}
grep -A10 "config lan_to_tailnet 'lan_to_tailnet'" "$WORK_DIR/files/etc/config/tailscale" | grep -q "option tailnet_to_lan '1'" || {
	echo "configurer should enable tailnet-to-LAN when input is true"
	exit 1
}

if "$CONFIGURER" "$WORK_DIR/files" maybe >/dev/null 2>&1; then
	echo "configurer accepted an invalid boolean value"
	exit 1
fi

echo "LAN-to-tailnet workflow input test passed"
