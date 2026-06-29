#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QCA_WORKFLOWS=(
	"$ROOT_DIR/.github/workflows/QCA-6.12-LiBwrt.yml"
	"$ROOT_DIR/.github/workflows/QCA-6.12-VIKINGYFY.yml"
	"$ROOT_DIR/.github/workflows/QCA-6.18-VIKINGYFY.yml"
)

grep -Fq 'UPDATE_PACKAGE "luci-app-wrtbak" "hotwa/luci-app-wrtbak" "main"' \
	"$ROOT_DIR/Scripts/Packages.sh"

grep -Fq 'CONFIG_PACKAGE_luci-app-wrtbak=y' "$ROOT_DIR/Config/GENERAL.txt"

grep -Fq 'WRTBAK_R2_PREFIX' "$ROOT_DIR/.github/workflows/WRT-CORE.yml"
grep -Fq 'Scripts/WrtbakR2Config.sh' "$ROOT_DIR/.github/workflows/WRT-CORE.yml"
grep -Fq 'Scripts/PrivateFirmwareGuard.sh' "$ROOT_DIR/.github/workflows/WRT-CORE.yml"
grep -Fq "if: env.WRT_PRIVATE_BUILD != 'true'" "$ROOT_DIR/.github/workflows/WRT-CORE.yml"

for workflow in "${QCA_WORKFLOWS[@]}"; do
	grep -Fq 'WRTBAK_DEVICE_ALIAS:' "$workflow" || {
		echo "$(basename "$workflow") missing WRTBAK_DEVICE_ALIAS input"
		exit 1
	}
	grep -Fq 'WRTBAK_PROXY_PROFILE:' "$workflow" || {
		echo "$(basename "$workflow") missing WRTBAK_PROXY_PROFILE input"
		exit 1
	}
	grep -Fq "WRTBAK_DEVICE_ALIAS: \${{ inputs.WRTBAK_DEVICE_ALIAS || '' }}" "$workflow" || {
		echo "$(basename "$workflow") does not pass WRTBAK_DEVICE_ALIAS into WRT-CORE"
		exit 1
	}
	grep -Fq "WRTBAK_PROXY_PROFILE: \${{ inputs.WRTBAK_PROXY_PROFILE || 'auto' }}" "$workflow" || {
		echo "$(basename "$workflow") does not pass WRTBAK_PROXY_PROFILE into WRT-CORE"
		exit 1
	}
done

echo "wrtbak package wiring checks passed"
