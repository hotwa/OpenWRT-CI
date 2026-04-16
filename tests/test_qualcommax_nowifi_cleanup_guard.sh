#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTIONS_SH="$ROOT_DIR/Scripts/function.sh"

[ -f "$FUNCTIONS_SH" ] || { echo "missing function.sh"; exit 1; }

grep -q '\[\[ "\$WRT_CONFIG" == \*"NOWIFI"\* || "\$WRT_CONFIG" == \*"WIFI-NO"\* \]\]' "$FUNCTIONS_SH" || {
	echo "function.sh does not trigger qualcommax Wi-Fi cleanup for WIFI-NO configs"
	exit 1
}

grep -q "sed -i 's/\\\\(ath11k-firmware-\\[^ ]\\*\\\\|ipq-wifi-\\[^ ]\\*\\\\|kmod-ath11k-\\[^ ]\\*\\\\)//g'" "$FUNCTIONS_SH" || {
	echo "function.sh no longer strips qualcommax ath11k and ipq-wifi package references during no-Wi-Fi builds"
	exit 1
}

echo "qualcommax no-wifi cleanup guard test passed"
