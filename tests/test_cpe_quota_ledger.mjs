import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {advance,counters,QuotaLedger} from '../Scripts/cpe5g-ipv6/quota-ledger.mjs';
import {accountingCommand} from '../Scripts/cpe5g-ipv6/probe.mjs';
import {execFileSync} from 'node:child_process';
const boot='11111111-1111-1111-1111-111111111111',other='22222222-2222-2222-2222-222222222222';
const sample={boot,rx:'20',tx:'10'},quota={enabled:true,limit:'1000',used:'500',blocked:false};
const mounts=()=>'/dev/mmcblk0p27 /data ext4 rw,noatime 0 0\n';
function fixture(t){
 const parent=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-ledger-'));fs.chmodSync(parent,0o700);
 t.after(()=>fs.rmSync(parent,{recursive:true,force:true}));
 return new QuotaLedger({directory:parent+'/quota',mounts});
}
test('first enrollment retains vendor history and subsequent use follows native increments',()=>{
 const first=advance(null,sample,'500');assert.equal(first.used,'500');
 assert.equal(advance(first,{...sample,rx:'25',tx:'12'},'8000000000').used,'507','ignore vendor wrap inflation after enrollment');
 assert.equal(advance(first,sample,'0').used,'500','vendor reset cannot replenish quota');
 assert.equal(advance(null,sample,'0').used,'30');
});
test('modem cold boot adds its current counters without dropping previous usage',()=>{
 const first=advance(null,sample,'500');
 const second=advance(first,{boot:other,rx:'3',tx:'4'},'7');assert.equal(second.used,'507');
 assert.equal(advance(second,{boot:other,rx:'5',tx:'8'},'0').used,'513');
});
test('counter regression in the same modem boot and corrupt samples refuse service',()=>{
 const first=advance(null,sample,'500');
 assert.throws(()=>advance(first,{...sample,rx:'19'},'0'),/regressed/);
 for(const bad of [{...sample,boot:'bad'},{...sample,rx:'-1'},{...sample,tx:'1.5'}])assert.throws(()=>advance(first,bad,'0'),/sample/);
 assert.throws(()=>advance({...first,used:'bad'},sample,'0'),/persistent/);
 assert.deepEqual(counters(`boot|${boot}\nrx|20\ntx|10\n`),sample);
 assert.throws(()=>counters('boot|bad\nrx|1\ntx|2'),/unavailable/);
 assert.match(accountingCommand,/CPE6_COUNTERS/);assert.match(accountingCommand,/kernel\/random\/boot_id/);assert.match(accountingCommand,/sipa_eth0\/statistics\/rx_bytes/);
 assert.doesNotMatch(accountingCommand,/vnstat.*--(?:remove|reset)/);
});
test('eMMC ledger survives router/process restart, modem restart and limit changes',t=>{
 const l=fixture(t);assert.equal(l.account(quota,sample).used,'500');
 const restarted=new QuotaLedger({directory:l.directory,mounts});
 assert.equal(restarted.account({...quota,used:'0'},{...sample,rx:'25'}).used,'505');
 const capped=restarted.account({...quota,limit:'508',used:'0'},{boot:other,rx:'2',tx:'1'});
 assert.equal(capped.used,'508');assert.equal(capped.blocked,true);
 assert.equal(restarted.account({...quota,enabled:false,limit:'0'},counters(`boot|${other}\nrx|2\ntx|1`)).blocked,false);
 assert.equal(fs.statSync(l.directory+'/ledger.json').mode&0o777,0o600);
});
test('missing, read-only, or RAM /data cannot bootstrap an unaccounted SIM session',t=>{
 const l=fixture(t);
 for(const raw of ['', 'tmpfs /data tmpfs rw 0 0', '/dev/mmcblk0p27 /data ext4 ro 0 0']){
  const bad=new QuotaLedger({directory:l.directory,mounts:()=>raw});assert.throws(()=>bad.account(quota,sample),/eMMC/);
 }
 assert.equal(fs.existsSync(l.directory),false);
});
test('symlink, invalid/private-mode ledger and unsafe directory fail closed',t=>{
 const l=fixture(t);l.account(quota,sample);const file=l.directory+'/ledger.json',saved=fs.readFileSync(file);
 fs.chmodSync(file,0o644);assert.throws(()=>l.account(quota,sample),/Unsafe/);fs.chmodSync(file,0o600);
 fs.writeFileSync(file,'{}');assert.throws(()=>l.account(quota,sample),/persistent/);
 fs.writeFileSync(file,saved);fs.renameSync(file,file+'.save');fs.symlinkSync(file+'.save',file);
 assert.throws(()=>l.account(quota,sample),/Unsafe/);fs.unlinkSync(file);fs.renameSync(file+'.save',file);
 fs.chmodSync(l.directory,0o777);assert.throws(()=>l.account(quota,sample),/Unsafe/);
});
test('same-boot regression leaves the last durable accounting evidence intact',t=>{
 const l=fixture(t);l.account(quota,sample);const file=l.directory+'/ledger.json',before=fs.readFileSync(file);
 assert.throws(()=>l.account(quota,{...sample,rx:'1'}),/regressed/);assert.deepEqual(fs.readFileSync(file),before);
});
test('real CPE overlay includes accounting module and sysupgrade ledger preservation',t=>{
 const root=path.resolve(import.meta.dirname,'..'),parent=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-quota-overlay-'));
 t.after(()=>fs.rmSync(parent,{recursive:true,force:true}));
 const files=parent+'/files';
 fs.mkdirSync(files+'/usr/libexec',{recursive:true});fs.writeFileSync(files+'/usr/libexec/cpe5g-mwan3-gated-reconcile','#!/bin/sh\n',{mode:0o755});
 execFileSync('bash',[root+'/Scripts/ConfigureCpeIpv6.sh',files,'true'],{cwd:parent,stdio:'pipe'});
 assert.equal(fs.readFileSync(files+'/usr/libexec/cpe5g-ipv6/quota-ledger.mjs','utf8'),fs.readFileSync(root+'/Scripts/cpe5g-ipv6/quota-ledger.mjs','utf8'));
 assert.match(fs.readFileSync(files+'/lib/upgrade/keep.d/cpe5g-lucky','utf8'),/\/data\/cpe5g-quota\//);
});
