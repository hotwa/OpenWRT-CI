#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/docs/upstream-merge-policy.md"
AGENTS="$ROOT_DIR/AGENTS.md"
README="$ROOT_DIR/README.md"
PACKAGES="$ROOT_DIR/Scripts/Packages.sh"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"

[ -f "$POLICY" ] || { echo "missing upstream merge policy"; exit 1; }

grep -Fq 'Do Not Merge From Upstream' "$POLICY" || {
	echo "upstream merge policy does not document rejected upstream changes"
	exit 1
}

for required in \
	'luci-app-nikki' \
	'jdcloud_re-cs-07' \
	'jdcloud_re-ss-01' \
	're-ss02' \
	'unraveloop/JDC-AX6600-Athena-LED-Controller' \
	'WrtbakR2Config.sh' \
	'PrivateFirmwareGuard.sh' \
	'CPE-5G.yml'
do
	grep -Fq "$required" "$POLICY" || {
		echo "upstream merge policy missing protected item: $required"
		exit 1
	}
done

grep -Fq 'docs/upstream-merge-policy.md' "$AGENTS" || {
	echo "AGENTS.md does not point agents to upstream merge policy"
	exit 1
}

grep -Fq 'docs/upstream-merge-policy.md' "$README" || {
	echo "README does not point maintainers to upstream merge policy"
	exit 1
}

for package_line in \
	'UPDATE_PACKAGE "noobwrt" "nooblk-98/luci-theme-noobwrt" "master"' \
	'UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"' \
	'UPDATE_PACKAGE "theme-fluent" "LazuliKao/luci-theme-fluent" "main"' \
	'UPDATE_PACKAGE "diskmanager" "4IceG/luci-app-mini-diskmanager" "main"' \
	'UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"' \
	'UPDATE_PACKAGE "netwizard" "sirpdboy/luci-app-netwizard" "main"' \
	'UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"' \
	'UPDATE_PACKAGE "luci-app-nginx-manager" "hello-yunshu/luci-app-nginx-manager" "main"'
do
	grep -Fq "$package_line" "$PACKAGES" || {
		echo "missing selectively absorbed upstream package source: $package_line"
		exit 1
	}
done

for config_line in \
	'CONFIG_PACKAGE_kmod-ata-ahci=y' \
	'CONFIG_PACKAGE_kmod-ata-core=y' \
	'CONFIG_PACKAGE_kmod-nvme=y' \
	'CONFIG_PACKAGE_exfat-fsck=y' \
	'CONFIG_PACKAGE_exfat-mkfs=y' \
	'CONFIG_PACKAGE_libnvme=y' \
	'CONFIG_PACKAGE_nvme-cli=y' \
	'CONFIG_PACKAGE_smartmontools=y' \
	'CONFIG_PACKAGE_smartmontools-drivedb=y'
do
	grep -Fq "$config_line" "$GENERAL" || {
		echo "missing selectively absorbed storage config: $config_line"
		exit 1
	}
done

echo "upstream merge policy checks passed"
