#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
node - "$repo" <<'NODE'
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const root=process.argv[2],tmp=fs.mkdtempSync(path.join(os.tmpdir(),'pi-native-mcp-'));
try {
 const fw=path.join(tmp,'firmware.json'),user=path.join(tmp,'settings.json');
 const run=()=>{const p=spawnSync(process.execPath,[path.join(root,'files/usr/sbin/pi-settings-merge.js'),fw,user],{encoding:'utf8'});assert.equal(p.status,0,p.stderr);return p.stdout.trim();};
 const original={defaultProvider:'commandcode',defaultModel:'keep/model',packages:['npm:pi-mcp-adapter@1.2.3','pi-mcp-adapter','git:github.com/nicobailon/pi-mcp-adapter','git:https://github.com/nicobailon/pi-mcp-adapter.git@main','npm:custom-plugin','/data/custom/pi-mcp-adapter.ts','git:github.com/other/pi-mcp-adapter'],extensions:['-builtin:mcp','/data/custom.ts','-builtin:other'],custom:{keep:true}};
 fs.writeFileSync(fw,JSON.stringify({packages:['npm:custom-plugin'],extensions:['builtin:mcp']}));fs.writeFileSync(user,JSON.stringify(original),{mode:0o600});
 assert.match(run(),/^changed /);
 const migrated=JSON.parse(fs.readFileSync(user));
 assert.deepEqual(migrated.packages,original.packages.slice(4));
 assert.deepEqual(migrated.extensions,['/data/custom.ts','-builtin:other','builtin:mcp']);
 assert.equal(migrated.defaultModel,original.defaultModel);assert.deepEqual(migrated.custom,original.custom);
 assert.equal(fs.statSync(user).mode&0o777,0o600);
 const inode=fs.statSync(user).ino;assert.equal(run(),'unchanged');assert.equal(fs.statSync(user).ino,inode);
 fs.writeFileSync(fw,JSON.stringify({packages:['npm:custom-plugin']}));fs.writeFileSync(user,JSON.stringify(original));assert.equal(run(),'unchanged','legacy firmware must not retire user packages');
 fs.writeFileSync(fw,JSON.stringify({packages:[],extensions:['builtin:mcp']}));fs.writeFileSync(user,JSON.stringify({packages:[],extensions:17}));const before=fs.readFileSync(user);const bad=spawnSync(process.execPath,[path.join(root,'files/usr/sbin/pi-settings-merge.js'),fw,user]);assert.notEqual(bad.status,0);assert.deepEqual(fs.readFileSync(user),before);
 console.log('Pi native MCP migration: retirement, preservation, idempotency and fail-closed checks passed');
} finally {fs.rmSync(tmp,{recursive:true,force:true});}
NODE
