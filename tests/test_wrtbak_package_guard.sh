#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERAL="$ROOT_DIR/Config/GENERAL.txt"
RE_CS_07="$ROOT_DIR/Config/IPQ60XX-RE-CS-07-NOWIFI.txt"
PACKAGES_SH="$ROOT_DIR/Scripts/Packages.sh"
WRT_CORE="$ROOT_DIR/.github/workflows/WRT-CORE.yml"

for config in "$GENERAL" "$RE_CS_07"; do
	grep -qx "# CONFIG_PACKAGE_luci-app-wrtbak is not set" "$config" || {
		echo "$(basename "$config") does not disable luci-app-wrtbak" >&2
		exit 1
	}
done

! grep -Fq "UPDATE_PACKAGE \"luci-app-wrtbak\"" "$PACKAGES_SH" || {
	echo "Packages.sh must not fetch luci-app-wrtbak" >&2
	exit 1
}
! grep -Fq "WRTBAK_" "$WRT_CORE" || {
	echo "WRT-CORE must not accept or inject wrtbak configuration" >&2
	exit 1
}
grep -Fq "luci-app-wrtbak must remain disabled in all firmware builds" "$WRT_CORE" || {
	echo "WRT-CORE does not assert that wrtbak stays disabled" >&2
	exit 1
}

echo "wrtbak is disabled in all firmware builds"
