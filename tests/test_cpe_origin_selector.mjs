import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import {fileURLToPath} from 'node:url';
import {test} from 'node:test';
import {nativeAddress,fromAddress} from '../Scripts/cpe5g-ipv6/model.mjs';
import {selectOriginIpv6,selectorMain,statusPath} from '../Scripts/cpe5g-ipv6/select-origin-ipv6.mjs';

const now=1791050000000,prefix='2001:db8:1234:5678::/64';
const origin=nativeAddress('20010db812345678');
const status=()=>({phase:'online',updated:now,prefix,address:origin,quota:{enabled:true,limit:'1000',used:'300',blocked:false}});
const info=()=>({family:'inet6',local:origin,prefixlen:128,scope:'global',flags:['permanent'],preferred_life_time:180,valid_life_time:180});
const kernel=()=>[{ifname:'usb0',addr_info:[info()]}];
function fixture({states=[status()],rows=kernel(),runError,readError,clock=()=>now}={}){
 let reads=0;
 const calls=[];
 return {calls,options:{now:clock,fs:{readFileSync(file,encoding){
  assert.equal(file,statusPath);assert.equal(encoding,'utf8');reads++;
  if(readError)throw readError;
  const state=states[Math.min(reads-1,states.length-1)];
  return typeof state==='string'?state:JSON.stringify(state);
 }},run(bin,args){
  calls.push([bin,args]);if(runError)throw runError;
  return typeof rows==='string'?rows:JSON.stringify(rows);
 }}};
}
function rejected(options){
 const f=fixture(options);let stdout='',stderr='';
 assert.throws(()=>selectOriginIpv6(f.options),/^Error: Native IPv6 origin is unavailable$/);
 assert.equal(selectorMain({...f.options,stdout:text=>{stdout+=text;},stderr:text=>{stderr+=text;}}),1);
 assert.equal(stdout,'');assert.equal(stderr,'Native IPv6 origin is unavailable\n');
}
test('selects exactly the controller-owned installed /128; import has no CLI side effects',()=>{
 const f=fixture();assert.equal(selectOriginIpv6(f.options),origin);
 assert.deepEqual(f.calls,[['ip',['-j','-6','addr','show','dev','usb0']]]);
 let stdout='',stderr='';assert.equal(selectorMain({...f.options,stdout:t=>{stdout+=t;},stderr:t=>{stderr+=t;}}),0);
 assert.equal(stdout,origin+'\n');assert.equal(stderr,'');
 const module=new URL('../Scripts/cpe5g-ipv6/select-origin-ipv6.mjs',import.meta.url).href;
 assert.equal(execFileSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(module)}); process.stdout.write('import-only');`],{encoding:'utf8'}),'import-only');
 const wrapper=fs.readFileSync(fileURLToPath(new URL('../Scripts/cpe5g-ipv6/select-origin-ipv6',import.meta.url)),'utf8');
 assert.match(wrapper,/exec \/usr\/bin\/node \/usr\/libexec\/cpe5g-ipv6\/select-origin-ipv6\.mjs/);
});
test('normalizes compressed and uppercase addresses and ignores unrelated first candidates',()=>{
 const s=status();s.prefix='2001:DB8:1234:5678:0:0:0:0/64';s.address='2001:DB8:1234:5678:0:C0DE:13:1';
 const rows=kernel();rows[0].addr_info=[{...info(),local:'2001:db8:1234:5678::11'}, {...info(),local:'fe80::1',scope:'link'}, {...info(),local:'2001:db8:ffff:1::1'}, {...info(),local:'2001:DB8:1234:5678:0:C0DE:13:1'}];
 assert.equal(selectOriginIpv6(fixture({states:[s],rows}).options),origin);
 assert.equal(fromAddress(origin).slice(16),'0000c0de00130001');
});
test('only fresh online status is accepted, including exact time boundaries',()=>{
 for(const [updated,valid] of [[now-45000,true],[now-45001,false],[now+5000,true],[now+5001,false],[null,false],[''+now,false],[-1,false],[NaN,false]]){
  const s=status();s.updated=updated;if(valid)assert.equal(selectOriginIpv6(fixture({states:[s]}).options),origin);else rejected({states:[s]});
 }
 for(const phase of ['offline','cleanup-pending','online ',null]){const s=status();s.phase=phase;rejected({states:[s]});}
 rejected({clock:()=>Infinity});
});
test('quota counters are independently checked with exact BigInt semantics',()=>{
 for(const quota of [null,{},[],{enabled:true,limit:'1000',used:'1000',blocked:false},{enabled:true,limit:'0',used:'0',blocked:false},
  {enabled:true,limit:'1000',used:'20',blocked:true},{enabled:false,limit:'0',used:'20',blocked:true},
  {enabled:'false',limit:'0',used:'20',blocked:false},{enabled:true,limit:1000,used:20,blocked:false},
  {enabled:true,limit:'1000',used:'-1',blocked:false},{enabled:true,limit:'1000',used:'1.5',blocked:false},
  {enabled:true,limit:'1000',used:'1e2',blocked:false},{enabled:true,limit:'1000',used:'0x20',blocked:false},
  {enabled:true,limit:'1000',used:' 20',blocked:false},{enabled:true,limit:'1000',used:'20',blocked:'false'}]){
  const s=status();s.quota=quota;rejected({states:[s]});
 }
 const s=status();s.quota={enabled:true,limit:'9007199254740993',used:'9007199254740992',blocked:false};
 assert.equal(selectOriginIpv6(fixture({states:[s]}).options),origin);
 s.quota.used=s.quota.limit;rejected({states:[s]});
 s.quota={enabled:false,limit:'0',used:'100000',blocked:false};assert.equal(selectOriginIpv6(fixture({states:[s]}).options),origin);
});
test('prefix must be a single GUA /64 and address must be exactly nativeAddress',()=>{
 for(const prefix of ['fc00:1234::/64','fe80::/64','ff02::/64','::/64','2001:db8:1234:5678::1/64','2001:db8:1234:5678::/56',
  '2001:db8:1234:5678::/064','2001:db8:1234:5678::/64/64','2001:db8:1234:5678::/64 2001:db8:ffff::/64',
  ['2001:db8:1234:5678::/64','2001:db8:ffff::/64'],null]){
  const s=status();s.prefix=prefix;rejected({states:[s]});
 }
 for(const address of ['2001:db8:1234:5678::11','2001:db8:ffff:1:0:c0de:13:1',origin+'%usb0',null,[origin]]){
  const s=status();s.address=address;rejected({states:[s]});
 }
});
test('kernel must contain one exact installed /128 with global scope and usable lifetimes',()=>{
 for(const patch of [{prefixlen:64},{prefixlen:'128'},{family:'inet'},{scope:'link'},
  {preferred_life_time:0},{preferred_life_time:null},{preferred_life_time:false},{preferred_life_time:-1},
  {valid_life_time:0},{valid_life_time:null},{flags:'deprecated'},
  ...['tentative','dadfailed','deprecated'].flatMap(flag=>[{flags:[flag]},{[flag]:true},{[flag]:'false'}])]){
  const rows=kernel();Object.assign(rows[0].addr_info[0],patch);rejected({rows});
 }
 for(const rows of [[],[...kernel(),...kernel()],[{ifname:'wan',addr_info:[info()]}],[{ifname:'usb0',addr_info:[]}],
  [{ifname:'usb0',addr_info:[info(),info()]}],[{ifname:'usb0',addr_info:[{...info(),local:'2001:db8:1234:5678::11'}]}]])rejected({rows});
 const rows=kernel();rows[0].addr_info[0].preferred_life_time='forever';rows[0].addr_info[0].valid_life_time='forever';
 assert.equal(selectOriginIpv6(fixture({rows}).options),origin);
 delete rows[0].addr_info[0].preferred_life_time;delete rows[0].addr_info[0].valid_life_time;
 rows[0].addr_info[0].preferred_lft=10;rows[0].addr_info[0].valid_lft=20;
 assert.equal(selectOriginIpv6(fixture({rows}).options),origin);
});
test('state changes during the kernel query cannot publish a superseded address',()=>{
 for(const mutate of [s=>{s.phase='offline';},s=>{s.quota.used='1000';s.quota.blocked=true;},s=>{s.updated=now-45001;},
  s=>{s.prefix='2001:db8:9999:1::/64';s.address=nativeAddress('20010db899990001');}]){
  const after=status();mutate(after);rejected({states:[status(),after]});
 }
 let n=0;rejected({clock:()=>now+(n++===0?0:45001)});
});
test('missing, malformed or failing local input yields empty stdout and generic stderr',()=>{
 for(const input of [{readError:Error('configuration-secret-value')},{runError:Error('configuration-secret-value')},
  {states:['not-json']},{states:['x'.repeat(131073)]},{rows:'not-json'},{rows:'x'.repeat(131073)}, {states:[null]}])rejected(input);
});
