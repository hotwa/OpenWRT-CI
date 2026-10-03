import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {Controller} from '../Scripts/cpe5g-ipv6/worker.mjs';
import {fromAddress} from '../Scripts/cpe5g-ipv6/model.mjs';
const local='fe80::13:2',remote='fe80::66:1',prefixA='2001:db8:13:1::/64',prefixB='2001:db8:13:2::/64';
const equalAddress=(a,b)=>fromAddress(a.split('/')[0])===fromAddress(b.split('/')[0]);
const ownLine=(prefix,table,proto=196)=>`${prefix} via ${local} dev usb0 table ${table} proto ${proto} metric 665`;
class Network {
 constructor(){
  this.prefix=prefixA;this.usbLinkLocal=remote;this.hasDefault=true;
  this.quota={enabled:true,limit:'10000',used:'100',blocked:false};
  this.routes=[];this.rules=[];this.upstream=[];this.calls=[];this.notifications=[];this.gates=[];
  this.uci=new Map([['dhcp.lan.ra_default','0'],['dhcp.lan.prefix_filter','fc00::/7']]);this.table='';this.addVendor(prefixA);
 }
 addVendor(prefix){for(const table of [181,200])this.upstream.push(`${prefix} dev usb0 table ${table} proto kernel metric 1024`);}
 sense=async()=>{
  if(this.senseFails)throw Error('ADB unavailable');
  return {prefix:this.prefix,prefixHex:this.prefix?fromAddress(this.prefix.split('/')[0]).slice(0,16):null,usbLinkLocal:this.usbLinkLocal,cellAddress:this.prefix?.replace('::/64','::1')||null,cpeAddresses:this.prefix?[this.prefix.replace('::/64','::66')]:[],quota:this.quota,hasDefault:this.hasDefault,routes:this.upstream.join('\n')};
 };
 run=(bin,args,input)=>{
  this.calls.push({bin,args:[...args],input});const cmd=args.join(' ');
  if(bin==='nft'){
   if(cmd==='list table inet cpe6_guard'){if(!this.table)throw Error('Table absent');return this.table;}
   assert.equal(cmd,'-f -');
   if(input.includes('table inet cpe6_guard {'))this.table=input;
   if(input.startsWith('flush set'))this.gates.push({ipv4:input.includes('add element inet cpe6_guard blocked '),ipv6:input.includes('add element inet cpe6_guard ipv6_blocked ')});
   return '';
  }
  if(bin==='uci'){
   if(args[1]==='get'){if(!this.uci.has(args[2]))throw Error('Option missing');return this.uci.get(args[2])+'\n';}
   assert.equal(args[0],'set');const at=args[1].indexOf('=');this.uci.set(args[1].slice(0,at),args[1].slice(at+1));return '';
  }
  if(bin==='/etc/init.d/odhcpd'){assert.deepEqual(args,['reload']);if(this.raFails)throw Error('RA reload failed');return '';}
  if(bin==='ubus'){
   if(cmd==='call network.interface.lan status')return JSON.stringify({l3_device:'br-lan'});
   assert.deepEqual(args.slice(0,3),['call','network.interface','notify_proto']);const body=JSON.parse(args[3]);this.notifications.push(body);
   if((!body['link-up']&&this.withdrawFails)||(body['link-up']&&this.notifyFails))throw Error('notify failed');return '';
  }
  assert.equal(bin,'ip');
  if(cmd==='-j -6 addr show dev usb0')return JSON.stringify(this.linkMissing?[]:[{addr_info:[{scope:'link',local}]}]);
  if(cmd==='-j -6 rule show'){if(this.ruleReadFails)throw Error('Rule read failed');return JSON.stringify(this.rules);}
  if(cmd==='-j -6 route show table all'){if(this.routeReadFails)throw Error('Route read failed');return JSON.stringify(this.routes);}
  const value=k=>args[args.indexOf(k)+1];
  if(cmd.startsWith('-6 rule add ')){
   assert.equal(value('protocol'),'196');const [mark,mask]=value('fwmark').split('/');this.rules.push(this.realRuleShape?{priority:Number(value('pref')),src:value('from').split('/')[0],srclen:64,fwmark:mark,fwmask:mask,table:value('lookup'),protocol:'196'}:{priority:Number(value('pref')),src:value('from'),fwmark:Number(mark),fwmask:Number(mask),table:Number(value('lookup')),protocol:196});return '';
  }
  if(cmd.startsWith('-6 rule del ')){
   assert.equal(value('protocol'),'196');this.rules=this.rules.filter(r=>!(Number(r.protocol)===196&&r.priority===613&&equalAddress(r.src,value('from'))));return '';
  }
  if(cmd.startsWith('-6 route flush ')){
   assert.equal(value('proto'),'196');assert.equal(value('table'),'613');this.routes=this.routes.filter(r=>!(Number(r.table)===613&&Number(r.protocol)===196));return '';
  }
  if(cmd.startsWith('-6 route replace ')){
   if(this.policyFails)throw Error('Policy install failed');assert.equal(value('proto'),'196');const dst=args[3]==='throw'?args[4]:args[3],table=Number(value('table'));
   this.routes=this.routes.filter(r=>Number(r.table)!==table||r.dst!==dst);this.routes.push({dst,table:this.realRuleShape?String(table):table,protocol:this.realRuleShape?'196':196});return '';
  }
  throw Error('Unexpected ip command '+cmd);
 };
 adb=async cmd=>{
  this.calls.push({bin:'adb',args:[cmd]});
  if(cmd.startsWith('ping6 ')){if(this.healthThrows)throw Error('Health transport failed');return this.healthFails?'ping failed':'CPE6_HEALTH_OK';}
  let m=cmd.match(/^ip -6 route add (\S+) via (\S+) dev usb0 table (181|200) proto 196 metric 665 /);
  if(m){
   const [,prefix,via,table]=m;
   if(Number(table)===this.addFails||this.upstream.some(l=>l.startsWith(prefix+' via ')&&l.includes('table '+table)&&l.includes('metric 665')))return 'RTNETLINK: File exists';
   this.upstream.push(`${prefix} via ${via} dev usb0 table ${table} proto 196 metric 665`);
   if(this.addAckLost)throw Error('ADB lost after route add');return 'CPE6_ROUTE_OK';
  }
  m=cmd.match(/^ip -6 route del (\S+) via (\S+) dev usb0 table (181|200) proto 196 metric 665 /);
  if(m){
   const [,prefix,via,table]=m;
   if(!this.deleteFails)this.upstream=this.upstream.filter(l=>!(equalAddress(l.split(' ')[0],prefix)&&l.includes('via ')&&equalAddress(l.split('via ')[1].split(' ')[0],via)&&l.includes('table '+table)&&l.includes('proto 196 ')&&l.includes('metric 665')));
   if(this.confirmFails)return 'route show failed';
   return this.upstream.filter(l=>l.includes('table '+table)).join('\n')+'\nCPE6_ROUTES_OK\n';
  }
  throw Error('Unexpected ADB command '+cmd);
 };
}
function setup(t,net=new Network()){
 const stateDir=fs.mkdtempSync(path.join(os.tmpdir(),'cpe6-controller-'));t.after(()=>fs.rmSync(stateDir,{recursive:true,force:true}));
 return {net,c:new Controller({run:net.run,adb:net.adb,sense:net.sense,stateDir}),stateDir};
}
async function cycle(c){try{await c.tick();}catch{await c.fail();}}
function lastGate(net){return net.gates.at(-1);}
const ownedUpstream=net=>net.upstream.filter(l=>l.includes('proto 196 '));

test('trusted quota with unavailable IPv6 withdraws only IPv6, including stop',async t=>{
 for(const absent of ['prefix','usbLinkLocal','hasDefault']){
  const {c,net}=setup(t);net[absent]=absent==='hasDefault'?false:null;await cycle(c);
  assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});assert.equal(c.current,null);assert.equal(net.notifications.at(-1)['link-up'],false);
  await c.stop();assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});
 }
});
test('untrusted and exceeded quota block IPv4 and IPv6 without changing counters',async t=>{
 for(const quota of [null,{enabled:true,limit:'100',used:'100',blocked:true},{enabled:true,limit:'0',used:'0',blocked:true},{enabled:true,limit:'bad',used:'1',blocked:false}]){
  const {c,net}=setup(t);net.quota=quota;await cycle(c);assert.deepEqual(lastGate(net),{ipv4:true,ipv6:true});assert.equal(net.quota,quota);
 }
 const {c,net}=setup(t);await c.tick();net.senseFails=true;await cycle(c);assert.deepEqual(lastGate(net),{ipv4:true,ipv6:true});assert.equal(c.lastTrustedQuota,null);
});
test('quota exhaustion after native IPv6 success cleans routes and gates both families',async t=>{
 const {c,net}=setup(t);await c.tick();net.quota={enabled:true,limit:'10000',used:'10000',blocked:true};await c.tick();
 assert.deepEqual(lastGate(net),{ipv4:true,ipv6:true});assert.equal(c.current,null);assert.equal(ownedUpstream(net).length,0);assert.equal(net.rules.length,0);
 net.quota={enabled:true,limit:'10000',used:'100',blocked:false};await c.tick();assert.deepEqual(lastGate(net),{ipv4:false,ipv6:false});assert.equal(c.current.prefix,prefixA);
});
test('DHCP broadcast and link-local multicast ND precede quota drops; public input guard remains',async t=>{
 const {c,net}=setup(t);await c.tick();const rules=net.table;
 assert.match(rules,/ip daddr 255\.255\.255\.255 udp sport 68 udp dport 67 accept/);
 assert.match(rules,/ip6 daddr ff02::\/16 meta l4proto ipv6-icmp icmpv6 type \{ 133, 134, 135, 136 \} accept/);
 assert.ok(rules.indexOf('udp sport 68')<rules.indexOf('oifname @blocked counter drop'));
 assert.ok(rules.indexOf('ip6 daddr ff02')<rules.indexOf('oifname @blocked counter drop'));
 assert.match(rules,/iifname "usb0" meta nfproto ipv6 counter drop/);
});
test('healthy install has owned policy and UDX routes; stop leaves normal IPv4 usable',async t=>{
 const {c,net}=setup(t);await c.tick();assert.equal(c.current.prefix,prefixA);assert.deepEqual(lastGate(net),{ipv4:false,ipv6:false});
 assert.equal(net.rules.length,1);assert.equal(net.rules[0].protocol,196);assert.equal(ownedUpstream(net).length,2);assert.equal(c.routes.size,2);
 const publishes=net.calls.findIndex(x=>x.bin==='ubus'&&x.args[2]==='notify_proto'&&JSON.parse(x.args[3])['link-up']);
 const policy=net.calls.findIndex(x=>x.bin==='ip'&&x.args.includes('add')&&x.args.includes('rule'));assert.ok(policy<publishes);
 const reloads=net.calls.filter(x=>x.bin==='/etc/init.d/odhcpd').length;await c.tick();assert.equal(net.calls.filter(x=>x.bin==='/etc/init.d/odhcpd').length,reloads);
 await c.stop();assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});assert.equal(net.rules.length,0);assert.equal(ownedUpstream(net).length,0);assert.equal(net.uci.get('dhcp.lan.prefix_filter'),'fc00::/7');assert.equal(net.uci.get('dhcp.lan.ra_default'),'0');
});
test('online worker repairs external reconcile RA reset without repeated reloads',async t=>{
 const {c,net}=setup(t);await c.tick();assert.equal(net.uci.get('dhcp.lan.prefix_filter'),'::/0');
 const before=net.calls.filter(x=>x.bin==='/etc/init.d/odhcpd').length;
 net.uci.set('dhcp.lan.prefix_filter','fc00::/7');net.uci.set('dhcp.lan.ra_default','1');await c.tick();
 assert.equal(c.current.prefix,prefixA);assert.equal(net.uci.get('dhcp.lan.prefix_filter'),'::/0');assert.equal(net.uci.get('dhcp.lan.ra_default'),'0');
 assert.equal(net.calls.filter(x=>x.bin==='/etc/init.d/odhcpd').length,before+1);
 const reads=net.calls.filter(x=>x.bin==='uci'&&x.args[1]==='get').length;await c.tick();
 assert.equal(net.calls.filter(x=>x.bin==='uci'&&x.args[1]==='get').length,reads+2);
 assert.equal(net.calls.filter(x=>x.bin==='/etc/init.d/odhcpd').length,before+1);
});
test('health, local link, policy and notification failures retain trusted IPv4',async t=>{
 for(const failed of ['healthFails','healthThrows','linkMissing','policyFails','notifyFails']){
  const {c,net}=setup(t);net[failed]=true;await cycle(c);assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true},failed);assert.equal(c.current,null);assert.equal(ownedUpstream(net).length,0);
 }
});
test('RA transition failure withdraws IPv6 and retries pending reload without blocking IPv4',async t=>{
 const {c,net}=setup(t);net.raFails=true;await cycle(c);assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});assert.equal(c.current,null);assert.equal(net.uci.get('dhcp.lan.prefix_filter'),'fc00::/7');
 net.raFails=false;await cycle(c);assert.equal(c.current.prefix,prefixA);assert.equal(net.uci.get('dhcp.lan.prefix_filter'),'::/0');
});
test('UDX route add failure is not registered; earlier acknowledged adds can be cleaned',async t=>{
 const {c,net}=setup(t);net.addFails=200;await assert.rejects(c.tick(),/CPE return route failed/);
 assert.equal(c.routes.size,1);assert.equal([...c.routes.values()][0].table,181);assert.equal(ownedUpstream(net).length,1);
 await c.fail();assert.equal(c.routes.size,0);assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});
});
test('route deletion needs confirmed absence, retains ledger on failure and retries',async t=>{
 const {c,net}=setup(t);await c.tick();net.deleteFails=true;await c.down('test');assert.equal(c.routes.size,2);assert.equal(ownedUpstream(net).length,2);
 net.deleteFails=false;net.confirmFails=true;await c.down('test');assert.equal(c.routes.size,2);assert.equal(ownedUpstream(net).length,0);
 net.confirmFails=false;await c.down('test');assert.equal(c.routes.size,0);assert.equal(ownedUpstream(net).length,0);
});
test('foreign rule or table occupation is refused and never removed',async t=>{
 for(const kind of ['rule','route','extra-selector']){
  const {c,net}=setup(t),foreign=kind==='route'?{table:613,dst:'default',protocol:99}:{priority:613,src:prefixA,fwmark:0,fwmask:255,table:613,protocol:kind==='rule'?99:196,...(kind==='extra-selector'?{ipproto:'tcp'}:{})};
  const collection=kind==='route'?'routes':'rules';net[collection].push(foreign);await cycle(c);assert.equal(c.current,null);assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});assert.ok(net[collection].includes(foreign));
 }
});
test('existing UDX route without protocol ownership is not adopted or deleted',async t=>{
 const {c,net}=setup(t);const foreign=ownLine(prefixA,181,99);net.upstream.push(foreign);await cycle(c);assert.equal(c.routes.size,0);assert.ok(net.upstream.includes(foreign));assert.equal(c.current,null);
});
test('withdraw failure still removes all owned policies and return routes',async t=>{
 const {c,net}=setup(t);await c.tick();net.withdrawFails=true;assert.equal(await c.down('test'),false);
 assert.equal(c.current,null);assert.equal(c.routes.size,0);assert.equal(ownedUpstream(net).length,0);assert.equal(net.rules.length,0);assert.equal(net.routes.filter(r=>r.table===613&&r.protocol===196).length,0);assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});
});
test('kernel rule inspection error still attempts owned-route cleanup',async t=>{
 const {c,net}=setup(t);await c.tick();net.ruleReadFails=true;await c.down('test');assert.equal(net.routes.filter(r=>r.table===613&&r.protocol===196).length,0);assert.equal(c.routes.size,0);
 net.ruleReadFails=false;await c.down('retry');assert.equal(net.rules.length,0);
});
test('restart after kill -9 recovers old prefix using protocol and keeps foreign state',async t=>{
 const {c,net,stateDir}=setup(t);await c.tick();const foreignUdx=ownLine(prefixA,181,99),foreignRule={priority:700,src:prefixA,table:700,protocol:99},foreignRoute={table:700,dst:prefixA,protocol:99};
 net.upstream.push(foreignUdx);net.rules.push(foreignRule);net.routes.push(foreignRoute);net.prefix=prefixB;net.addVendor(prefixB);
 const restarted=new Controller({run:net.run,adb:net.adb,sense:net.sense,stateDir});await restarted.tick();
 assert.equal(restarted.current.prefix,prefixB);assert.equal(ownedUpstream(net).length,2);assert.ok(ownedUpstream(net).every(l=>equalAddress(l.split(' ')[0],prefixB)));
 assert.ok(net.rules.includes(foreignRule));assert.ok(net.routes.includes(foreignRoute));assert.ok(net.upstream.includes(foreignUdx));
 assert.ok(net.rules.filter(r=>r.protocol===196).every(r=>equalAddress(r.src,prefixB)));
});
test('lost route-add acknowledgement is recovered by the next owned snapshot',async t=>{
 const {c,net}=setup(t);net.addAckLost=true;await cycle(c);assert.equal(c.routes.size,0);assert.equal(ownedUpstream(net).length,1);
 net.addAckLost=false;await cycle(c);assert.equal(c.current.prefix,prefixA);assert.equal(ownedUpstream(net).length,2);
});
test('router-only mode never changes LAN RA settings or adds UDX downstream routes',async t=>{
 const {net,stateDir}=setup(t);const c=new Controller({run:net.run,adb:net.adb,sense:net.sense,stateDir,mode:'router'});await c.tick();await c.stop();assert.equal(ownedUpstream(net).length,0);assert.ok(!net.calls.some(x=>x.bin==='uci'||x.bin==='/etc/init.d/odhcpd'));
});
test('real iproute2 source plus srclen JSON survives recurrence and restart',async t=>{
 const {c,net,stateDir}=setup(t);net.realRuleShape=true;await c.tick();await c.tick();
 assert.equal(c.current.prefix,prefixA);assert.equal(net.rules.length,1);assert.equal(net.rules[0].srclen,64);assert.ok(!net.rules[0].src.includes('/'));assert.equal(net.rules[0].protocol,'196');
 net.prefix=prefixB;net.addVendor(prefixB);const restarted=new Controller({run:net.run,adb:net.adb,sense:net.sense,stateDir});await restarted.tick();await restarted.tick();
 assert.equal(restarted.current.prefix,prefixB);assert.equal(net.rules.length,1);assert.ok(equalAddress(net.rules[0].src,prefixB));assert.equal(ownedUpstream(net).length,2);
 await restarted.stop();assert.equal(net.rules.length,0);assert.equal(net.routes.filter(r=>Number(r.table)===613&&Number(r.protocol)===196).length,0);
 const deletes=net.calls.filter(x=>x.bin==='ip'&&x.args[1]==='rule'&&x.args[2]==='del');assert.ok(deletes.length>=2);assert.ok(deletes.every(x=>x.args[x.args.indexOf('from')+1].endsWith('/64')));
});
test('conflicting rule source lengths stay foreign even with protocol 196',async t=>{
 for(const foreign of [
  {priority:613,src:prefixA,srclen:128,fwmark:'0',fwmask:'0xff',table:'613',protocol:'196'},
  {priority:613,src:prefixA.replace('/64',''),srclen:128,fwmark:'0',fwmask:'0xff',table:'613',protocol:196},
  {priority:613,src:prefixA.replace('/64',''),fwmark:'0',fwmask:'0xff',table:'613',protocol:196},
 ]){
  const {c,net}=setup(t);net.rules.push(foreign);await cycle(c);assert.equal(c.current,null);assert.ok(net.rules.includes(foreign));assert.deepEqual(lastGate(net),{ipv4:false,ipv6:true});
 }
});
test('duplicate process lock refuses live owner and recovers a dead owner',t=>{
 const {c,net,stateDir}=setup(t);c.acquireLock();const duplicate=new Controller({run:net.run,adb:net.adb,sense:net.sense,stateDir});assert.throws(()=>duplicate.acquireLock(),/already running/);c.releaseLock();
 fs.mkdirSync(stateDir+'/worker.lock');fs.writeFileSync(stateDir+'/worker.lock/pid','99999999');duplicate.acquireLock();assert.equal(fs.readFileSync(stateDir+'/worker.lock/pid','utf8'),String(process.pid));duplicate.releaseLock();
});

test('shutdown commands enforce their deadline even when a child ignores SIGTERM',t=>{
 const {stateDir}=setup(t),c=new Controller({stateDir});c.shutdownDeadline=Date.now()+3500;const started=Date.now();
 assert.throws(()=>c.run(process.execPath,['-e','process.on("SIGTERM",()=>{});setInterval(()=>{},100);setTimeout(()=>process.exit(),2500);']),e=>e.signal==='SIGKILL');
 assert.ok(Date.now()-started<1500,'an ignored TERM must not exhaust netifd teardown');
});

test('real SIGTERM interrupts pending probe/health/add and idle delay before netifd SIGKILL',async t=>{
 for(const stage of ['sense','health','add','idle','cleanup']){
  const {stateDir}=setup(t),worker=new URL('../Scripts/cpe5g-ipv6/worker.mjs',import.meta.url).href,transport=new URL('../Scripts/cpe5g-ipv6/adb.mjs',import.meta.url).href,probe=new URL('../Scripts/cpe5g-ipv6/probe.mjs',import.meta.url).href,model=new URL('../Scripts/cpe5g-ipv6/model.mjs',import.meta.url).href;
  // Reuse the network fixture, but hold an actual TCP ADB transport and run
  // the same signal entry point as the production worker in another process.
  const source=`import assert from 'node:assert/strict';import fs from 'node:fs';import net from 'node:net';
import {Controller,runController} from ${JSON.stringify(worker)};import {shell,packet} from ${JSON.stringify(transport)};import {read} from ${JSON.stringify(probe)};import {fromAddress} from ${JSON.stringify(model)};
const local=${JSON.stringify(local)},remote=${JSON.stringify(remote)},prefixA=${JSON.stringify(prefixA)},prefixB=${JSON.stringify(prefixB)};
const equalAddress=${equalAddress.toString()};${Network.toString()}
const stage=${JSON.stringify(stage)},emit=x=>{if(x.event==='pending')n.withdrawFails=true;console.log(JSON.stringify(x));},sockets=new Set();
const server=net.createServer(socket=>{sockets.add(socket);socket.on('error',()=>{});socket.on('close',()=>sockets.delete(socket));let bytes=Buffer.alloc(0);
socket.on('data',chunk=>{bytes=Buffer.concat([bytes,chunk]);while(bytes.length>=24){const size=bytes.readUInt32LE(12);if(bytes.length<24+size)return;const name=bytes.subarray(0,4).toString();bytes=bytes.subarray(24+size);
if(name==='CNXN')socket.write(packet('CNXN',0x01000000,4096,'device::\\0'));if(name==='OPEN'){socket.write(packet('OKAY',7,1));emit({event:stage==='cleanup'?'cleanup-held':'pending'});if(stage==='cleanup'){const heartbeat=setInterval(()=>socket.write(packet('WRTE',7,1,'still-held')),200);socket.once('close',()=>clearInterval(heartbeat));}}}});});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const n=new Network();let ticks=0,c;
const run=(bin,args,input)=>{emit({event:'call',bin,args,input});return n.run(bin,args,input);};
const sense=async options=>{ticks++;if(ticks===2&&stage==='sense')return read('127.0.0.1',server.address().port,options);if(ticks===2&&stage==='health')c.lastHealth=0;if(ticks===2&&stage==='add'){n.prefix=prefixB;n.addVendor(prefixB);}return n.sense();};
const adb=(cmd,options)=>(stage==='cleanup'&&cmd.startsWith('ip -6 route del '))||(ticks===2&&((stage==='health'&&cmd.startsWith('ping6 '))||(stage==='add'&&cmd.startsWith('ip -6 route add '))))?shell('127.0.0.1',server.address().port,cmd,options):n.adb(cmd);
c=new Controller({run,adb,sense,stateDir:${JSON.stringify(stateDir)}});if(!['idle','cleanup'].includes(stage))c.interval=0.01;
const status=c.status.bind(c);c.status=(phase,detail)=>{status(phase,detail);if(phase==='online'&&['idle','cleanup'].includes(stage))emit({event:'pending'});};
try{await runController(c);emit({event:'final',gate:n.gates.at(-1),prefix:n.uci.get('dhcp.lan.prefix_filter'),rules:n.rules,routes:n.routes,current:c.current,pendingRoutes:c.routes.size,locked:fs.existsSync(c.stateDir+'/worker.lock')});}
finally{for(const socket of sockets)socket.destroy();await new Promise(r=>server.close(r));}`;
  const events=[];let stderr='',signalTime=0,tail='';
  const child=spawn(process.execPath,['--input-type=module','-e',source],{stdio:['ignore','pipe','pipe']});
  const result=await new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{child.kill('SIGKILL');reject(Error(stage+' shutdown exceeded netifd grace period'));},7000);
   child.stdout.on('data',chunk=>{tail+=chunk;let at;while((at=tail.indexOf('\n'))>=0){const line=tail.slice(0,at);tail=tail.slice(at+1);const event=JSON.parse(line);events.push(event);if(event.event==='pending'&&!signalTime){signalTime=Date.now();child.kill('SIGTERM');}}});
   child.stderr.on('data',chunk=>{stderr+=chunk;});child.once('error',e=>{clearTimeout(timer);reject(e);});child.once('exit',(code,signal)=>{clearTimeout(timer);resolve({code,signal});});
  });
  assert.deepEqual(result,{code:0,signal:null},stage+': '+stderr);assert.ok(signalTime,stage+' reached the in-flight phase');assert.ok(Date.now()-signalTime<(stage==='cleanup'?4500:3000),stage+' did not withdraw promptly');
  const pendingAt=events.findIndex(x=>x.event==='pending'),later=events.slice(pendingAt+1),final=events.find(x=>x.event==='final');
  assert.ok(final,stage+' completed cleanup');assert.deepEqual(final.gate,{ipv4:false,ipv6:true});assert.equal(final.prefix,'fc00::/7');assert.equal(final.rules.length,0);assert.equal(final.routes.length,0);assert.equal(final.current,null);assert.equal(final.locked,false);
  if(stage==='cleanup'){assert.equal(final.pendingRoutes,2);assert.equal(later.filter(x=>x.event==='cleanup-held').length,1);assert.ok(later.findIndex(x=>x.event==='call'&&x.bin==='ip'&&x.args.includes('flush'))<later.findIndex(x=>x.event==='cleanup-held'),'local owned policy must be removed before remote wait');}
  assert.ok(later.every(x=>x.event!=='call'||!(x.bin==='ip'&&(x.args.includes('replace')||x.args.includes('add')))),stage+' installed a policy after stop');
  assert.ok(later.every(x=>x.event!=='call'||!(x.bin==='ubus'&&x.args[2]==='notify_proto'&&JSON.parse(x.args[3])['link-up'])),stage+' published after stop');
  assert.ok(later.every(x=>x.event!=='call'||!(x.bin==='uci'&&x.args.includes('dhcp.lan.prefix_filter=::/0'))),stage+' enabled LAN RA after stop');
  assert.ok(later.every(x=>x.event!=='call'||!(x.bin==='nft'&&x.input?.startsWith('flush set')&&!x.input.includes('add element inet cpe6_guard ipv6_blocked'))),stage+' reopened IPv6 after stop');
 }
});
