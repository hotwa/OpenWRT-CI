#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -Fq 'UPDATE_PACKAGE "luci-app-wrtbak" "hotwa/luci-app-wrtbak" "main"' \
	"$ROOT_DIR/Scripts/Packages.sh"

grep -Fq 'CONFIG_PACKAGE_luci-app-wrtbak=y' "$ROOT_DIR/Config/GENERAL.txt"

echo "wrtbak package wiring checks passed"
