import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {nativeAddress} from '../Scripts/cpe5g-ipv6/model.mjs';
import {PublicAccess,publicConfig,sourcePrefix,readyFor,installedAddress,publicSetBatch,publicQuota,readRootJson,guardDefinition,guardVersion,publicMark,certificatePinPath} from '../Scripts/cpe5g-ipv6/public-access.mjs';

const address=nativeAddress('20010db800130001'),now=Date.now();
const config={enabled:true,hostname:'cpe.jmsu.top',allowed_sources:['2001:db8:eeee::/48']};
const quota={enabled:true,limit:'1000',used:'10',blocked:false};
const ready={ready:true,hostname:config.hostname,port:18443,address,updated:now};
const mtlsConfig={enabled:true,hostname:'cpe.lucky.jmsu.top',source_policy:'mtls',client_ca_sha256:'a'.repeat(64),server_cert_sha256:'b'.repeat(64)};
const pin={version:1,hostname:mtlsConfig.hostname,origin_sni:'cpe-origin.jmsu.top',server_cert_sha256:mtlsConfig.server_cert_sha256};
const mtlsReady={...ready,hostname:mtlsConfig.hostname,source_policy:'mtls',client_ca_sha256:mtlsConfig.client_ca_sha256,server_cert_sha256:mtlsConfig.server_cert_sha256,mtls_verified:true,origin_header_verified:true};
const rows=[{ifname:'usb0',addr_info:[{family:'inet6',scope:'global',local:address,prefixlen:128,preferred_life_time:180,valid_life_time:180}]}];
// Real CPE nft 1.1.6 listing captured after its first mTLS lease. Only the
// subscriber address is replaced with a documentation prefix in this fixture.
const nft116LeaseListing=`table inet cpe6_guard {
 comment "cpe5g-ipv6-v4"
 set blocked {
  type ifname
 }
 set ipv6_blocked {
  type ifname
 }
 set public_sources {
  type ipv6_addr
  flags interval
  auto-merge
 }
 set public_address {
  type ipv6_addr
  size 1
  timeout 45s
  gc-interval 5s
 }
 set public_mtls_address {
  type ipv6_addr
  size 1\t# count 1
  timeout 45s
  gc-interval 5s
  elements = { 2001:db8:13:1:0:c0de:13:1 expires 16s880ms }
 }
 chain public_origin {
  iifname @ipv6_blocked counter packets 0 bytes 0 drop
  ip6 saddr @public_sources ip6 daddr @public_address meta mark set meta mark | 0x40000000 accept
  ip6 daddr @public_mtls_address meta mark set meta mark | 0x40000000 accept
  counter packets 0 bytes 0 drop
 }
 chain input {
  type filter hook input priority -15; policy accept;
  iifname "usb0" meta nfproto ipv6 tcp dport 18443 jump public_origin
  iifname "usb0" meta nfproto ipv6 ct state established,related accept
  iifname "usb0" ip6 saddr fe80::/10 accept
  iifname "usb0" meta l4proto ipv6-icmp accept
  iifname "usb0" meta nfproto ipv6 udp dport 41641 accept
  iifname "usb0" meta nfproto ipv6 counter packets 47 bytes 6872 drop
 }
 chain output {
  type filter hook output priority -15; policy accept;
  oifname "usb0" ip daddr 192.168.66.0/24 accept
  oifname "usb0" ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept
  oifname "usb0" ip6 daddr fe80::/10 accept
  oifname "usb0" ip6 daddr ff02::/16 icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
  meta nfproto ipv6 oifname @ipv6_blocked counter packets 25 bytes 3948 drop
  oifname @blocked counter packets 7 bytes 1198 drop
 }
 chain forward {
  type filter hook forward priority -15; policy accept;
  oifname "usb0" ip daddr 192.168.66.0/24 accept
  oifname "usb0" ip6 daddr fe80::/10 accept
  meta nfproto ipv6 oifname @ipv6_blocked counter packets 0 bytes 0 drop
  oifname @blocked counter packets 0 bytes 0 drop
 }
}\n`;
function fixture(){
 const calls=[],state={config,ready,rows,pin,deploying:false};
 const gate=new PublicAccess({now:()=>now,configFile:'config',readyFile:'ready',pinFile:'pin',readJson:file=>state[file],deploying:()=>state.deploying,
  run:(bin,args,input)=>{calls.push({bin,args,input});if(bin==='ip')return JSON.stringify(state.rows);return '';}
 });
 return {gate,calls,state};
}
const refresh=gate=>gate.refresh({online:true,address,quota});
test('certificate deployment closes the public exception even with old fresh readiness',()=>{
 const {gate,state,calls}=fixture();assert.equal(refresh(gate),true);
 state.deploying=true;assert.equal(refresh(gate),false);assert.equal(calls.at(-1).input,publicSetBatch());
 state.deploying=false;assert.equal(refresh(gate),true);
});

test('only root-approved explicit IPv6 sources and a single FQDN can enable the origin',()=>{
 assert.equal(publicConfig(null),null);assert.equal(publicConfig({enabled:false}),null);
 assert.equal(publicConfig(config).sources[0],'2001:db8:eeee:0:0:0:0:0/48');
 assert.equal(sourcePrefix('2001:db8:eeee::1234/48'),'2001:db8:eeee:0:0:0:0:0/48');
 for(const source of ['::/0','0:0:0:0:0:0:0:0/0','1.1.1.1','::ffff:192.0.2.1','2001:db8::/129','2001:db8::/','2001:db8::/32;accept',null])assert.throws(()=>publicConfig({...config,allowed_sources:[source]}));
 for(const sources of [[],null,'2001:db8::/32'])assert.throws(()=>publicConfig({...config,allowed_sources:sources}));
 for(const hostname of ['*.jmsu.top','https://cpe.jmsu.top','cpe.jmsu.top/','cpe.jmsu.top.','-cpe.jmsu.top','localhost','192.0.2.1'])assert.throws(()=>publicConfig({...config,hostname}));
});
test('readiness binds fresh timestamp, exact address, fixed port and approved hostname',()=>{
 const parsed=publicConfig(config);assert.equal(readyFor(ready,parsed,address,now),true);
 assert.equal(readyFor({...ready,address:address.toUpperCase()},parsed,address,now),true);
 for(const change of [{updated:now-30001},{updated:now+5001},{updated:'recent'},{port:443},{address:'2001:db8::1'},{hostname:'other.jmsu.top'},{ready:false}])assert.equal(readyFor({...ready,...change},parsed,address,now),false);
});
test('mTLS must be explicit, pinned and verified; an empty IP list never changes authentication modes',()=>{
 assert.equal(publicConfig(mtlsConfig).source_policy,'mtls');
 assert.equal(publicConfig({...mtlsConfig,allowed_sources:[]}).source_policy,'mtls');
 assert.equal(readyFor(mtlsReady,publicConfig(mtlsConfig),address,now),true);
 for(const change of [{source_policy:'unknown'},{source_policy:null},{client_ca_sha256:undefined},{client_ca_sha256:'a'.repeat(63)},{server_cert_sha256:'not-a-digest'},{allowed_sources:['::/0']},{allowed_sources:['2000::/3']},{allowed_sources:['2001:db8::/32']}])assert.throws(()=>publicConfig({...mtlsConfig,...change}));
 assert.throws(()=>publicConfig({...config,allowed_sources:[],client_ca_sha256:mtlsConfig.client_ca_sha256,server_cert_sha256:mtlsConfig.server_cert_sha256}));
 for(const change of [{source_policy:undefined},{source_policy:'allowlist'},{mtls_verified:false},{mtls_verified:'true'},{origin_header_verified:false},{origin_header_verified:undefined},{client_ca_sha256:'c'.repeat(64)},{server_cert_sha256:'c'.repeat(64)},{client_ca_sha256:undefined},{updated:now-30001},{address:'2001:db8::1'}])assert.equal(readyFor({...mtlsReady,...change},publicConfig(mtlsConfig),address,now),false);
 assert.equal(readyFor(mtlsReady,publicConfig(config),address,now),false);
 assert.equal(readyFor(ready,publicConfig(mtlsConfig),address,now),false);
});
test('certificate pin is a separate exact origin identity and supersedes only the server digest',()=>{
 assert.equal(certificatePinPath,'/etc/lucky/cert-sync/cpe5g-origin/current/certificate-pin.json');
 assert.equal(publicConfig({...mtlsConfig,server_cert_sha256:'stale'},pin).server_cert_sha256,pin.server_cert_sha256);
 assert.equal(publicConfig({...mtlsConfig,server_cert_sha256:undefined},pin).server_cert_sha256,pin.server_cert_sha256);
 for(const change of [{version:2},{version:'1'},{hostname:'cpe.jmsu.top'},{origin_sni:'other.jmsu.top'},{server_cert_sha256:undefined},{server_cert_sha256:'bad'}])assert.throws(()=>publicConfig(mtlsConfig,{...pin,...change}));
 assert.throws(()=>publicConfig({...mtlsConfig,hostname:'other.jmsu.top'},pin));
 assert.throws(()=>publicConfig(mtlsConfig,null));
 const {gate,state,calls}=fixture();state.config=mtlsConfig;state.ready=mtlsReady;
 assert.equal(refresh(gate),true);
 for(const invalid of [undefined,null,{...pin,origin_sni:'other.jmsu.top'},{...pin,server_cert_sha256:'c'.repeat(64)}]){
  state.pin=invalid;assert.equal(refresh(gate),false);assert.equal(calls.at(-1).input,publicSetBatch());
 }
 state.pin=pin;state.config={...mtlsConfig,server_cert_sha256:'stale'};assert.equal(refresh(gate),true);
});
test('native address must exist as a preferred, valid /128 on usb0',()=>{
 assert.equal(installedAddress(rows,address),true);
 for(const change of [{tentative:true},{dadfailed:true},{deprecated:true},{flags:['tentative']},{flags:['dadfailed']},{flags:['deprecated']},{preferred_life_time:0},{valid_life_time:0},{prefixlen:64},{local:'2001:db8::1'},{scope:'link'}])assert.equal(installedAddress([{ifname:'usb0',addr_info:[{...rows[0].addr_info[0],...change}]}],address),false);
 assert.equal(installedAddress([{...rows[0],ifname:'wan'}],address),false);
 assert.equal(installedAddress([],address),false);
});
test('quota must be internally trustworthy and below its enabled limit',()=>{
 assert.equal(publicQuota(quota),true);
 for(const q of [null,{blocked:false},{...quota,used:'1000'},{...quota,blocked:true},{...quota,limit:'0'},{...quota,used:'bad'}])assert.equal(publicQuota(q),false);
});
test('healthy origin refreshes one short-lived address; missing/bad config closes only public sets',()=>{
 const {gate,calls,state}=fixture();assert.equal(refresh(gate),true);
 assert.match(calls.at(-1).input,new RegExp(`public_address \\{ ${address} timeout 45s \\}`));
 assert.ok(!calls.at(-1).input.includes('ipv6_blocked'));
 for(const bad of [null,{...config,allowed_sources:[]},{...config,allowed_sources:['::/0']},{...config,hostname:'*.jmsu.top'}]){
  state.config=bad;assert.equal(refresh(gate),false);assert.equal(calls.at(-1).input,publicSetBatch());
 }
});
test('stale readiness, unusable address, down and untrusted quota flush the public exception',()=>{
 const {gate,calls,state}=fixture();
 state.ready={...ready,updated:now-30001};assert.equal(refresh(gate),false);
 state.ready=ready;state.rows=[];assert.equal(refresh(gate),false);
 state.rows=rows;
 for(const context of [{online:false,address,quota},{online:true,address,quota:null},{online:true,address,quota:{...quota,blocked:true}}])assert.equal(gate.refresh(context),false);
 assert.ok(calls.filter(x=>x.bin==='nft').every(x=>x.input===publicSetBatch()));
});
test('mTLS grants only its one expiring destination without an invented IP allowlist',()=>{
 const {gate,calls,state}=fixture();state.config=mtlsConfig;state.ready=mtlsReady;
 assert.equal(refresh(gate),true);const batch=calls.at(-1).input;
 assert.match(batch,new RegExp(`public_mtls_address \\{ ${address} timeout 45s \\}`));
 assert.ok(!batch.includes('add element inet cpe6_guard public_sources'));
 assert.ok(!batch.includes('::/0'));assert.ok(!batch.includes('2000::/3'));
 state.ready={...mtlsReady,origin_header_verified:false};assert.equal(refresh(gate),false);assert.equal(calls.at(-1).input,publicSetBatch());
 state.ready=mtlsReady;
 for(const invalid of [null,{...quota,used:quota.limit},{...quota,blocked:true}]){assert.equal(gate.refresh({online:true,address,quota:invalid}),false);assert.equal(calls.at(-1).input,publicSetBatch());}
 assert.equal(gate.refresh({online:false,address,quota}),false);
});
test('root JSON rejects writable files and symlinks',t=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-public-root-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 const file=dir+'/config.json';fs.writeFileSync(file,JSON.stringify(config),{mode:0o600});
 if(process.getuid()===0)assert.deepEqual(readRootJson(file),config);else assert.throws(()=>readRootJson(file),/root-controlled/);
 fs.chmodSync(file,0o666);assert.throws(()=>readRootJson(file),/root-controlled/);
 fs.symlinkSync(file,dir+'/link.json');assert.throws(()=>readRootJson(dir+'/link.json'));
});
test('table ownership requires the complete known guard, not just a copied marker',()=>{
 for(const version of [1,2,3,4])assert.equal(guardVersion(guardDefinition('usb0',version),'usb0'),version);
 assert.equal(guardVersion(guardDefinition('usb0',1,true),'usb0'),1);
 for(const bad of [guardDefinition('usb0',1).replace('counter drop','counter accept'),guardDefinition('usb0',1).replace('chain input {','chain foreign {\n}\n chain input {'),guardDefinition('usb0',2).replace('size 1','size 2'),guardDefinition('usb0',1).replace('elements = { "usb0" }','elements = { "wan" }'),guardDefinition('usb0',1).replace('iifname "usb0"','iifname "u sb0"'),guardDefinition('usb0',4).replace('0x40000000','0x00000001'),guardDefinition('usb0',4).replace('meta mark set meta mark | 0x40000000','ct mark set ct mark | 0x40000000')])assert.equal(guardVersion(bad,'usb0'),null);
 const rules=guardDefinition('usb0');
 assert.ok(rules.indexOf('tcp dport 18443 jump public_origin')<rules.indexOf('ct state established,related accept'));
 assert.equal(publicMark,0x40000000);
 assert.ok(rules.indexOf('iifname @ipv6_blocked counter drop')<rules.indexOf('ip6 saddr @public_sources ip6 daddr @public_address meta mark set meta mark | 0x40000000 accept'));
 assert.ok(rules.indexOf('iifname @ipv6_blocked counter drop')<rules.indexOf('ip6 daddr @public_mtls_address meta mark set meta mark | 0x40000000 accept'));
 assert.ok(!rules.includes('ct mark'));
});
test('nft 1.1.6 occupied singleton count annotations preserve exact guard ownership',()=>{
 assert.equal(guardVersion(nft116LeaseListing,'usb0'),4);
 assert.equal(guardVersion(nft116LeaseListing.replace('size 1\t# count 1','size 1\t# count 0'),'usb0'),4);
 const allowlist=nft116LeaseListing.replace('set public_address {\n  type ipv6_addr\n  size 1',
  'set public_address {\n  type ipv6_addr\n  size 1\t# count 1');
 assert.equal(guardVersion(allowlist,'usb0'),4);
 for(const bad of [
  nft116LeaseListing.replace('# count 1','# count 2'),
  nft116LeaseListing.replace('# count 1','# count 1 accept'),
  nft116LeaseListing.replace('size 1\t# count 1','size 2\t# count 1'),
  nft116LeaseListing.replace('gc-interval 5s','gc-interval 1s'),
  nft116LeaseListing.replace('meta mark set meta mark | 0x40000000','ct mark set ct mark | 0x40000000'),
  nft116LeaseListing.replace('0x40000000','0x00000001'),
  nft116LeaseListing.replace('chain input {','chain foreign { counter accept }\n chain input {'),
  nft116LeaseListing.replace('type ifname\n }','type ifname\n elements = { "wan" }\n }'),
  nft116LeaseListing.replace('counter packets 0 bytes 0 drop','counter packets 0 bytes 0 accept'),
  nft116LeaseListing.replace('counter packets 0 bytes 0 drop','counter packets 0 bytes 0 drop # count 1')
 ])assert.equal(guardVersion(bad,'usb0'),null);
});
// nft on the CI runner rejects the socket used for Node child-process stdin.
// Keep the real namespace checks while giving nft a private regular rules file.
const realNftTransport=`import fs from 'node:fs';import os from 'node:os';import path from 'node:path';
const run=(bin,args,input)=>{
 const index=bin==='nft'?args.findIndex((arg,i)=>arg==='-f'&&args[i+1]==='-'):-1;
 if(index<0)return execFileSync(bin,args,{input,encoding:'utf8',stdio:['pipe','pipe','pipe']});
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-public-nft-'));
 try{
  fs.chmodSync(directory,0o700);
  const file=path.join(directory,'rules.nft');fs.writeFileSync(file,input,{mode:0o600,flag:'wx'});
  const directoryStat=fs.statSync(directory),fileStat=fs.lstatSync(file);
  assert.equal(directoryStat.mode&0o777,0o700);assert.equal(directoryStat.uid,process.getuid());
  assert.equal(fileStat.mode&0o777,0o600);assert.equal(fileStat.uid,process.getuid());assert.ok(fileStat.isFile());
  const fileArgs=[...args];fileArgs[index+1]=file;
  return execFileSync(bin,fileArgs,{encoding:'utf8',stdio:['pipe','pipe','pipe']});
 }finally{fs.rmSync(directory,{recursive:true,force:true});}
};`;
test('real nft namespace accepts migration, refresh and expiry syntax and preserves foreign tables',t=>{
 const available=spawnSync('unshare',['--net','sh','-c','command -v nft >/dev/null && nft list ruleset'],{encoding:'utf8'});
 if(available.status!==0){t.skip('nft network namespace unavailable: '+available.stderr.trim());return;}
 const publicModule=new URL('../Scripts/cpe5g-ipv6/public-access.mjs',import.meta.url).href;
 const workerModule=new URL('../Scripts/cpe5g-ipv6/worker.mjs',import.meta.url).href;
 const code=`import assert from 'node:assert/strict';import {execFileSync} from 'node:child_process';
import {Controller} from ${JSON.stringify(workerModule)};
import {guardDefinition,guardVersion,publicSetBatch} from ${JSON.stringify(publicModule)};
${realNftTransport}
run('nft',['-f','-'],guardDefinition('usb0',1));
assert.equal(guardVersion(run('nft',['list','table','inet','cpe6_guard']),'usb0'),1);
const c=new Controller({run});c.firewall();c.firewall();
let listing=run('nft',['list','table','inet','cpe6_guard']);assert.equal(guardVersion(listing,'usb0'),4);
run('nft',['-f','-'],publicSetBatch(${JSON.stringify(address)},['2001:db8:eeee::/48']));
const live=JSON.parse(run('nft',['-j','list','set','inet','cpe6_guard','public_address']));
const set=live.nftables.find(x=>x.set).set;assert.equal(set.elem.length,1);assert.equal(set.timeout,45);assert.ok(set.flags.includes('timeout'));assert.ok(set.elem[0].elem.expires>0&&set.elem[0].elem.expires<=45);
c.firewall();run('nft',['-f','-'],publicSetBatch(${JSON.stringify(address)},[],'mtls'));
const mtlsSet=JSON.parse(run('nft',['-j','list','set','inet','cpe6_guard','public_mtls_address'])).nftables.find(x=>x.set).set;
assert.equal(mtlsSet.elem.length,1);assert.equal(mtlsSet.timeout,45);assert.ok(mtlsSet.elem[0].elem.expires>0&&mtlsSet.elem[0].elem.expires<=45);
listing=run('nft',['list','table','inet','cpe6_guard']);assert.equal(guardVersion(listing,'usb0'),4);
// Newer nft adds this generated count comment; the lease remains intact.
const annotated=listing.replace(/(set public_mtls_address \\{[\\s\\S]*?size 1)([^\\n]*)/,(_,prefix,suffix)=>prefix+(/# count/.test(suffix)?suffix:'\\t# count 1'));
assert.equal(guardVersion(annotated,'usb0'),4);run('nft',['-c','-f','-'],annotated);
c.firewall();
const retained=JSON.parse(run('nft',['-j','list','set','inet','cpe6_guard','public_mtls_address'])).nftables.find(x=>x.set).set;assert.equal(retained.elem.length,1);
run('nft',['add','rule','inet','cpe6_guard','input','counter','accept']);
const occupied=run('nft',['list','table','inet','cpe6_guard']);assert.equal(guardVersion(occupied,'usb0'),null);assert.throws(()=>c.firewall(),/Reserved firewall table occupied/);
run('nft',['delete','table','inet','cpe6_guard']);run('nft',['-f','-'],guardDefinition('usb0'));
const allowSet=JSON.parse(run('nft',['-j','list','set','inet','cpe6_guard','public_address'])).nftables.find(x=>x.set).set;assert.equal((allowSet.elem||[]).length,0);
c.firewall();run('nft',['-f','-'],publicSetBatch());
for(const version of [2,3]){
 run('nft',['delete','table','inet','cpe6_guard']);run('nft',['-f','-'],guardDefinition('usb0',version));c.firewall();assert.equal(guardVersion(run('nft',['list','table','inet','cpe6_guard']),'usb0'),4);
 const afterMigration=JSON.parse(run('nft',['-j','list','set','inet','cpe6_guard','public_mtls_address'])).nftables.find(x=>x.set).set;
 assert.equal((afterMigration.elem||[]).length,0);
}
run('nft',['add','rule','inet','cpe6_guard','input','counter','accept']);
listing=run('nft',['list','table','inet','cpe6_guard']);assert.throws(()=>c.firewall(),/Reserved firewall table occupied/);
assert.equal(run('nft',['list','table','inet','cpe6_guard']),listing);`;
 const result=spawnSync('unshare',['--net',process.execPath,'--input-type=module','-e',code],{encoding:'utf8',timeout:10000});
 assert.equal(result.status,0,result.stderr);
});
test('actual fw4 fence rejects absent/old guards and established traffic after withdrawal',t=>{
 const available=spawnSync('unshare',['--net','sh','-c','command -v nft >/dev/null && command -v ip >/dev/null && command -v nsenter >/dev/null && nft list ruleset'],{encoding:'utf8'});
 if(available.status!==0){t.skip('nft packet namespace unavailable: '+available.stderr.trim());return;}
 const publicModule=new URL('../Scripts/cpe5g-ipv6/public-access.mjs',import.meta.url).href;
 const workerModule=new URL('../Scripts/cpe5g-ipv6/worker.mjs',import.meta.url).href;
 const fence=fs.readFileSync(new URL('../Scripts/cpe5g-ipv6/origin-input-fence.nft',import.meta.url),'utf8');
 const peerCode=`import net from 'node:net';import readline from 'node:readline';
let socket;
const connect=()=>new Promise(resolve=>{
 socket=net.connect({host:${JSON.stringify(address)},port:18443,localAddress:'2001:db8:13:1::2'});
 const timer=setTimeout(()=>{socket.destroy();resolve(false);},250);
 socket.on('error',()=>{clearTimeout(timer);resolve(false);});socket.once('connect',()=>{clearTimeout(timer);resolve(true);});
});
const exchange=()=>new Promise(resolve=>{
 if(!socket||socket.destroyed)return resolve(false);
 const timer=setTimeout(()=>{socket.destroy();resolve(false);},250);
 socket.once('data',data=>{clearTimeout(timer);resolve(data.toString()==='echo');});socket.once('error',()=>{clearTimeout(timer);resolve(false);});socket.write('echo');
});
console.log(JSON.stringify({ready:true,pid:process.pid}));
for await(const line of readline.createInterface({input:process.stdin})){
 const request=JSON.parse(line);let ok=false;
 if(request.action==='connect')ok=await connect();
 if(request.action==='exchange')ok=await exchange();
 if(request.action==='close'){socket?.destroy();socket=null;ok=true;}
 console.log(JSON.stringify({id:request.id,ok}));
}
socket?.destroy();`;
 const code=`import assert from 'node:assert/strict';import net from 'node:net';import readline from 'node:readline';import {spawn,execFileSync} from 'node:child_process';
import {Controller} from ${JSON.stringify(workerModule)};
import {guardDefinition,publicSetBatch} from ${JSON.stringify(publicModule)};
${realNftTransport}
const peer=spawn('unshare',['--net',process.execPath,'--input-type=module','-e',${JSON.stringify(peerCode)}],{stdio:['pipe','pipe','pipe']});
let peerError='';peer.stderr.on('data',data=>{peerError+=data;});
const lines=readline.createInterface({input:peer.stdout}),responses=new Map();let nextId=0;
const first=new Promise((resolve,reject)=>{lines.once('line',line=>resolve(JSON.parse(line)));peer.once('exit',()=>reject(Error('peer exited: '+peerError)));});
lines.on('line',line=>{const response=JSON.parse(line);if(response.id)responses.get(response.id)?.(response.ok);});
const request=action=>new Promise(resolve=>{const id=++nextId;responses.set(id,ok=>{responses.delete(id);resolve(ok);});peer.stdin.write(JSON.stringify({id,action})+'\\n');});
const serverSockets=new Set(),server=net.createServer(socket=>{serverSockets.add(socket);socket.once('close',()=>serverSockets.delete(socket));socket.on('error',()=>{});socket.on('data',data=>socket.write(data));});let listening=false;
try{
 const info=await first;assert.equal(info.ready,true);
 run('ip',['link','add','usb0','type','veth','peer','name','peer0']);run('ip',['link','set','peer0','netns',String(info.pid)]);
 run('ip',['link','set','lo','up']);run('ip',['link','set','usb0','up']);run('ip',['-6','addr','add',${JSON.stringify(address+'/64')},'dev','usb0','nodad']);
 for(const args of [['link','set','lo','up'],['link','set','peer0','up'],['-6','addr','add','2001:db8:13:1::2/64','dev','peer0','nodad']])run('nsenter',['-t',String(info.pid),'-n','ip',...args]);
 await new Promise(resolve=>server.listen(18443,'::',resolve));listening=true;
 // Simulate both a preexisting mark and fw4 established/port accepts. The
 // actual source fence must remove only its reserved bit and block before
 // either ordinary accept can admit an ungranted packet.
 run('nft',['-f','-'],'table inet fw4 {\\n'+${JSON.stringify(fence)}+'\\nchain prior_mark { type filter hook input priority -25; policy accept; meta nfproto ipv6 tcp dport 18443 iifname != "lo" meta mark set meta mark | 0x40000100; }\\nchain input { type filter hook input priority 0; policy accept; meta nfproto ipv6 tcp dport 18443 iifname != "lo" meta mark & 0x40000100 != 0x00000100 counter drop; ct state established,related accept; tcp dport 18443 accept; }\\n}\\n');
 const loopback=net.connect({host:'::1',port:18443});await new Promise((resolve,reject)=>{loopback.once('connect',resolve);loopback.once('error',reject);});loopback.end();
 assert.equal(await request('connect'),false,'an absent native guard must reject forged premarks');
 run('nft',['-f','-'],guardDefinition('usb0',3));
 const unblock=()=>run('nft',['-f','-'],'flush set inet cpe6_guard blocked\\nflush set inet cpe6_guard ipv6_blocked\\n');
 const grant=()=>run('nft',['-f','-'],publicSetBatch(${JSON.stringify(address)},[],'mtls'));
 unblock();grant();assert.equal(await request('connect'),false,'a legacy accepting guard cannot supply the v4 mark');
 const c=new Controller({run});c.firewall();unblock();
 assert.equal(await request('connect'),false,'migration begins with no public grant');
 grant();assert.equal(await request('connect'),true,'fresh owned v4 grant passes the static fence');
 assert.equal(await request('exchange'),true,'reserved bit is cleared while other packet marks survive');
 run('nft',['-f','-'],'add element inet cpe6_guard ipv6_blocked { "usb0" }\\n');
 assert.equal(await request('exchange'),false,'quota gate closes established traffic despite a fresh address grant');await request('close');
 assert.equal(await request('connect'),false,'quota gate rejects new traffic despite a fresh address grant');
 unblock();grant();assert.equal(await request('connect'),true);assert.equal(await request('exchange'),true);
 run('nft',['-f','-'],publicSetBatch());
 assert.equal(await request('exchange'),false,'withdrawal closes already established connections');await request('close');
 grant();assert.equal(await request('connect'),true);assert.equal(await request('exchange'),true);
 run('nft',['delete','table','inet','cpe6_guard']);
 assert.equal(await request('exchange'),false,'guard deletion closes already established connections before fw4 accepts');await request('close');
 run('nft',['-f','-'],guardDefinition('usb0'));unblock();grant();
 run('ip',['link','set','usb0','down']);run('ip',['link','set','usb0','name','wan0']);run('ip',['link','set','wan0','up']);
 assert.equal(await request('connect'),false,'a grant for usb0 does not allow another ingress');
}finally{
 peer.stdin.end();peer.kill('SIGKILL');for(const socket of serverSockets)socket.destroy();if(listening)await new Promise(resolve=>server.close(resolve));else server.close();
}`;
 const result=spawnSync('unshare',['--net',process.execPath,'--input-type=module','-e',code],{encoding:'utf8',timeout:10000});
 assert.equal(result.status,0,result.stderr);
});
