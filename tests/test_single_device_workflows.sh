#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for wf in "RE-CS-02-OPENCLAW-BUILD.yml" "RE-CS-07-BUILD.yml" "RE-SS-01-BUILD.yml"; do
	path="$ROOT_DIR/.github/workflows/$wf"
	[ -f "$path" ] || { echo "missing workflow $wf"; exit 1; }
	grep -Fq 'inputs:' "$path"
	grep -Fq 'LAN_IP:' "$path"
	grep -Fq 'secrets: inherit' "$path"
	grep -Fq 'WRT_IP: ${{ inputs.LAN_IP' "$path"
done

grep -Fq 'WRT_OPENCLAW: true' "$ROOT_DIR/.github/workflows/RE-CS-02-OPENCLAW-BUILD.yml"
! grep -Fq 'WRT_OPENCLAW: true' "$ROOT_DIR/.github/workflows/RE-SS-01-BUILD.yml"

echo "all single device workflows passed guards"
