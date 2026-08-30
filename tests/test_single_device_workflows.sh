#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -RniE 'openclaw|luci-app-openclaw' "$ROOT_DIR/.github/workflows"; then
	echo "OpenClaw must not be referenced by any GitHub Actions workflow" >&2
	exit 1
fi

for wf in "RE-Mesh-BUILD.yml" "RE-CS-07-BUILD.yml"; do
	path="$ROOT_DIR/.github/workflows/$wf"
	[ -f "$path" ] || { echo "missing workflow $wf"; exit 1; }
	grep -Fq 'inputs:' "$path"
	grep -Fq 'secrets: inherit' "$path"
done

MESH="$ROOT_DIR/.github/workflows/RE-Mesh-BUILD.yml"
grep -Fq 'strategy:' "$MESH"
grep -Fq 'RE_SS_01_LAN_IP:' "$MESH"
grep -Fq 'RE_CS_02_LAN_IP:' "$MESH"
grep -Fq 'IPQ60XX-RE-SS-01' "$MESH"
grep -Fq 'IPQ60XX-RE-CS-02' "$MESH"
grep -Fq 'jdcloud_re-ss-01' "$MESH"
grep -Fq 'jdcloud_re-cs-02' "$MESH"

[ ! -e "$ROOT_DIR/.github/workflows/RE-SS-01-BUILD.yml" ]
[ ! -e "$ROOT_DIR/.github/workflows/RE-CS-02-BUILD.yml" ]

echo "RE mesh and NOWIFI workflows passed guards"
