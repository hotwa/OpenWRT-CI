#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -RniE 'openclaw|luci-app-openclaw' "$ROOT_DIR/.github/workflows"; then
	echo "OpenClaw must not be referenced by any GitHub Actions workflow" >&2
	exit 1
fi

for wf in "RE-CS-02-BUILD.yml" "RE-CS-07-BUILD.yml" "RE-SS-01-BUILD.yml"; do
	path="$ROOT_DIR/.github/workflows/$wf"
	[ -f "$path" ] || { echo "missing workflow $wf"; exit 1; }
	grep -Fq 'inputs:' "$path"
	grep -Fq 'LAN_IP:' "$path"
	grep -Fq 'secrets: inherit' "$path"
	grep -Fq 'WRT_IP: ${{ inputs.LAN_IP' "$path"
done

echo "all single device workflows passed guards"
