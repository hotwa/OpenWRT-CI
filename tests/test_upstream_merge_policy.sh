#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/docs/upstream-merge-policy.md"
AGENTS="$ROOT_DIR/AGENTS.md"
README="$ROOT_DIR/README.md"
PACKAGES="$ROOT_DIR/Scripts/Packages.sh"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
AUTO_CLEAN="$ROOT_DIR/.github/workflows/Auto-Clean.yml"
WORKFLOW_DIR="$ROOT_DIR/.github/workflows"

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

[ -f "$AUTO_CLEAN" ] || { echo "missing Auto-Clean workflow"; exit 1; }

[ "$(grep -Ec '^[[:space:]]*-[[:space:]]*cron:' "$AUTO_CLEAN")" -eq 1 ] &&
	grep -Eq '^[[:space:]]*-[[:space:]]*cron:[[:space:]]*["'"'"']?0[[:space:]]+20[[:space:]]+\*[[:space:]]+\*[[:space:]]+0["'"'"']?[[:space:]]*$' "$AUTO_CLEAN" || {
	echo "Auto-Clean must run on its single weekly schedule"
	exit 1
}

grep -Eq '^[[:space:]]*delete_releases:[[:space:]]*false[[:space:]]*$' "$AUTO_CLEAN" || {
	echo "Auto-Clean must not delete releases"
	exit 1
}

grep -Eq '^[[:space:]]*workflows_keep_day:[[:space:]]*30[[:space:]]*$' "$AUTO_CLEAN" || {
	echo "Auto-Clean must retain workflow runs and private artifacts for 30 days"
	exit 1
}

while IFS= read -r workflow; do
	if awk '
		function indentation(line) {
			match(line, /[^ \t]/)
			return RSTART ? RSTART - 1 : length(line)
		}
		/^[ \t]*USE_QIUSIMONS_DAE_MAKEFILE:[ \t]*$/ {
			in_setting = 1
			setting_indent = indentation($0)
			next
		}
		in_setting {
			if ($0 ~ /^[ \t]*(#.*)?$/) next
			if (indentation($0) <= setting_indent) {
				in_setting = 0
				next
			}
			normalized = tolower($0)
			sub(/#.*/, "", normalized)
			gsub(/[[:space:]"\047]/, "", normalized)
			if (normalized == "default:true") bad = 1
		}
		END { exit bad ? 0 : 1 }
	' "$workflow"; then
		echo "production workflow defaults USE_QIUSIMONS_DAE_MAKEFILE to true: $workflow"
		exit 1
	fi
done < <(find "$WORKFLOW_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print)

if grep -RniE --include='*.sh' --include='*.yml' --include='*.yaml' \
	'qiusimons/(luci-app-)?dae([/.]|$)' "$PACKAGES" "$ROOT_DIR/diy.sh" "$WORKFLOW_DIR"; then
	echo "production paths must not dynamically replace dae Makefile from QiuSimons"
	exit 1
fi

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
