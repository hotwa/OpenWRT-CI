#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
node - "$repo" <<'NODE'
const fs=require('node:fs'),assert=require('node:assert/strict'),root=process.argv[2];
const read=p=>fs.readFileSync(root+'/'+p,'utf8');
const catalog=JSON.parse(read('Scripts/node-agent-runtime/package.json'));
const settings=JSON.parse(read('files/etc/pi/agent/settings.json'));
for (const file of ['CPE-5G.yml','RE-Mesh-BUILD.yml','RE-CS-07-BUILD.yml']) assert(read('.github/workflows/'+file).includes('uses: ./.github/workflows/WRT-CORE.yml'));
assert(read('.github/workflows/WRT-CORE.yml').includes('Scripts/fetch_node_runtime.sh'));
assert.equal(catalog.dependencies['@cortexkit/pi-magic-context'],'latest');
assert(catalog.openwrtPiOptionalExtensions.includes('@cortexkit/pi-magic-context'));
assert(!settings.packages.some(x=>x.includes('pi-magic-context')));
assert(settings.packages.some(x=>x.includes('pi-agent-modes')));
assert(!settings.packages.some(x=>x.includes('pi-plan-mode')));
for(const p of ['Scripts/ensure_pi_extension_peers.js','Scripts/verify_pi_extensions.js'])assert(read(p).includes('...(catalog.openwrtPiOptionalExtensions || [])'));
for(const p of ['files/etc/profile.d/20-node-agent.sh','files/etc/init.d/multica'])assert(read(p).includes('MAGIC_CONTEXT_STORAGE_DIR=/data/cortexkit/magic-context'));
assert(read('files/etc/init.d/agent-data-prep').includes('link_directory "$DATA_ROOT/cortexkit/config" "$ROOT_HOME/.config/cortexkit"'));
NODE
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/nested/onnxruntime-node/bin" "$scratch/other-model"
printf preserve > "$scratch/other-model/data"
# Exercise the actual build pruning function without installing native packages.
source <(sed -n '/^prune_foreign_platform_builds() {/,/^}/p' "$repo/Scripts/fetch_node_runtime.sh")
NODE_LIB_DIR=$scratch
log_info() { :; }
elf_machine_id() { return 1; }
foreign_os_binary() { return 1; }
prune_foreign_platform_builds arm64
[ ! -e "$scratch/nested/onnxruntime-node" ]
[ "$(cat "$scratch/other-model/data")" = preserve ]
echo 'Magic Context optional preload, persistence and native pruning checks passed'
