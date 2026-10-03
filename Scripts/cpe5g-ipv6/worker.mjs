// netifd owns this process. No dial, CFUN, quota-reset or enrollment commands.
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {shell} from './adb.mjs';
import {read} from './probe.mjs';
import {update,withdraw,fromAddress,ipv6,stockUsbRoute} from './model.mjs';
const delay=n=>new Promise(r=>setTimeout(r,n));
const protocol=196,tableId=613;
function trustedQuota(q){
 if(!q||typeof q.enabled!=='boolean'||typeof q.blocked!=='boolean'||!/^\d+$/.test(q.limit)||!/^\d+$/.test(q.used))return null;
 const blocked=q.enabled&&(BigInt(q.limit)===0n||BigInt(q.used)>=BigInt(q.limit));
 return blocked===q.blocked?{...q}:null;
}
function rulePrefix(r){
 if(typeof r.src!=='string')throw Error('Rule source unavailable');
 const parts=r.src.split('/');if(parts.length>2)throw Error('Malformed rule source');
 const embedded=parts.length===2?parts[1]:null,provided=r.srclen===undefined?null:String(r.srclen);
 if((embedded!==null&&embedded!=='64')||(provided!==null&&provided!=='64')||(embedded===null&&provided===null))throw Error('Unexpected rule source length');
 const hex=fromAddress(parts[0]);if(!hex.endsWith('0000000000000000'))throw Error('Rule source is not a prefix');
 return ipv6(hex)+'/64';
}
function ownRule(r){
 const fields=new Set(['priority','src','srclen','fwmark','fwmask','table','protocol']);
 if(Object.keys(r).some(k=>!fields.has(k)))return false;
 try{return Number(r.priority)===tableId&&String(r.protocol)===String(protocol)&&Number(r.table)===tableId&&Number(r.fwmark)===0&&Number(r.fwmask)===255&&!!rulePrefix(r);}catch{return false;}
}
function ownedRoutes(raw,defaultTable){
 const found=[];
 for(const line of String(raw||'').split('\n')){
  const p=line.trim().split(/\s+/),value=k=>p.includes(k)?p[p.indexOf(k)+1]:undefined;
  try{
   const table=Number(value('table')||defaultTable),address=p[0].split('/')[0],hex=fromAddress(address),local=value('via'),localHex=fromAddress(local);
   if(![181,200].includes(table)||value('proto')!==String(protocol)||value('metric')!=='665'||value('dev')!=='usb0'||p[0].split('/')[1]!=='64'||!hex.endsWith('0000000000000000')||(parseInt(localHex.slice(0,4),16)&0xffc0)!==0xfe80)continue;
   found.push({prefix:ipv6(hex)+'/64',table,local:ipv6(localHex)});
  }catch{/* A vendor or foreign route is never ours. */}
 }
 return found;
}
const routeKey=r=>r.table+':'+fromAddress(r.prefix.split('/')[0]);
const withoutOwned=s=>({...s,routes:String(s.routes||'').split('\n').filter(l=>!ownedRoutes(l).length).join('\n')});
export class Controller {
 constructor({interfaceName='cpe6',device='usb0',host='192.168.66.1',port=5555,lan='lan',mode='lan',interval=15,lifetime=180,healthInterval=60,run,adb,sense,stateDir='/var/run/cpe5g-ipv6'}={}){
  for(const x of [interfaceName,device,lan])if(!/^[A-Za-z0-9_-]{1,32}$/.test(x))throw Error('Invalid interface name');
  if(![port,interval,lifetime,healthInterval].every(Number.isInteger)||port<1||port>65535||!['lan','router'].includes(mode)||interval<5||interval>300||lifetime<3*interval||lifetime>600||healthInterval<30||healthInterval>600)throw Error('Invalid lifetime or mode');
  Object.assign(this,{interfaceName,device,host,port,lan,mode,interval,lifetime,healthInterval,stateDir});
  this.run=run||((bin,args,input)=>execFileSync(bin,args,{input,encoding:'utf8',timeout:10000,stdio:['pipe','pipe','pipe']}));
  this.adb=adb||(cmd=>shell(host,port,cmd));this.sense=sense||(()=>read(host,port));this.routes=new Map();this.current=null;this.lastHealth=0;this.stopping=false;this.lastTrustedQuota=null;this.recovered=false;
 }
 tryRun(bin,args,input){try{return this.run(bin,args,input);}catch{return '';}}
 status(phase,detail){fs.mkdirSync(this.stateDir,{recursive:true,mode:0o700});fs.writeFileSync(this.stateDir+'/status.json',JSON.stringify({phase,detail,prefix:this.current?.prefix||null,quota:this.lastTrustedQuota,updated:Date.now()}),{mode:0o600});}
 notify(body){this.run('ubus',['call','network.interface','notify_proto',JSON.stringify(body)]);}
 blockIPv4(){return !this.lastTrustedQuota||this.lastTrustedQuota.blocked;}
 acquireLock(){
  fs.mkdirSync(this.stateDir,{recursive:true,mode:0o700});const lock=this.stateDir+'/worker.lock';
  try{fs.mkdirSync(lock,{mode:0o700});}catch(e){
   if(e.code!=='EEXIST')throw e;
   let pid;try{pid=Number(fs.readFileSync(lock+'/pid','utf8'));}catch{}
   if(Number.isSafeInteger(pid)&&pid>0){try{process.kill(pid,0);throw Error('IPv6 controller already running');}catch(e){if(e.code!=='ESRCH')throw e;}}
   else if(Date.now()-fs.statSync(lock).mtimeMs<30000)throw Error('IPv6 controller lock is being acquired');
   fs.rmSync(lock,{recursive:true});fs.mkdirSync(lock,{mode:0o700});
  }
  fs.writeFileSync(lock+'/pid',String(process.pid),{mode:0o600});this.lock=lock;
 }
 releaseLock(){if(this.lock&&fs.readFileSync(this.lock+'/pid','utf8')===String(process.pid)){fs.rmSync(this.lock,{recursive:true});this.lock=null;}}
 firewall(){
  const existing=this.tryRun('nft',['list','table','inet','cpe6_guard']);
  if(existing&&!existing.includes('cpe5g-ipv6-v1'))throw Error('Reserved firewall table occupied');
  if(existing&&existing.includes('set ipv6_blocked'))return;
  // Atomically upgrade our older table; never delete a foreign table.
  this.run('nft',['-f','-'],`${existing?'delete table inet cpe6_guard\n':''}table inet cpe6_guard {
 comment "cpe5g-ipv6-v1"
 set blocked { type ifname; elements = { "${this.device}" }; }
 set ipv6_blocked { type ifname; elements = { "${this.device}" }; }
 chain input { type filter hook input priority -15; policy accept;
  iifname "${this.device}" meta nfproto ipv6 ct state established,related accept
  iifname "${this.device}" ip6 saddr fe80::/10 accept
  iifname "${this.device}" meta l4proto ipv6-icmp accept
  iifname "${this.device}" meta nfproto ipv6 udp dport 41641 accept
  iifname "${this.device}" meta nfproto ipv6 counter drop
 }
 chain output { type filter hook output priority -15; policy accept;
  oifname "${this.device}" ip daddr 192.168.66.0/24 accept
  oifname "${this.device}" ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept
  oifname "${this.device}" ip6 daddr fe80::/10 accept
  oifname "${this.device}" ip6 daddr ff02::/16 meta l4proto ipv6-icmp icmpv6 type { 133, 134, 135, 136 } accept
  meta nfproto ipv6 oifname @ipv6_blocked counter drop
  oifname @blocked counter drop
 }
 chain forward { type filter hook forward priority -15; policy accept;
  oifname "${this.device}" ip daddr 192.168.66.0/24 accept
  oifname "${this.device}" ip6 daddr fe80::/10 accept
  meta nfproto ipv6 oifname @ipv6_blocked counter drop
  oifname @blocked counter drop
 }
}\n`);
 }
 gate(blocked,ipv6Blocked=blocked){
  this.firewall();this.run('nft',['-f','-'],`flush set inet cpe6_guard blocked\n${blocked?`add element inet cpe6_guard blocked { "${this.device}" }\n`:''}flush set inet cpe6_guard ipv6_blocked\n${ipv6Blocked?`add element inet cpe6_guard ipv6_blocked { "${this.device}" }\n`:''}`);
 }
 lanGate(online){
  if(this.mode!=='lan')return;
  // Reconcile/restore can reset UCI while the worker remains online. Re-read
  // the two managed options each cycle, but reload only after actual changes.
  this.lanOnline=undefined;
  const wanted=online?'::/0':'fc00::/7';let changed=false;
  for(const [key,value] of [['ra_default','0'],['prefix_filter',wanted]]){
   const option=`dhcp.${this.lan}.${key}`;
   if(this.tryRun('uci',['-q','get',option]).trim()!==value){this.run('uci',['set',option+'='+value]);changed=true;}
  }
  // UCI deltas live in RAM; the managed boot preset supplies the safe default.
  if(changed)this.lanReloadPending=true;
  if(this.lanReloadPending){this.run('/etc/init.d/odhcpd',['reload']);this.lanReloadPending=false;}
  this.lanOnline=online;
 }
 localLink(){const rows=JSON.parse(this.run('ip',['-j','-6','addr','show','dev',this.device]));const a=rows.flatMap(x=>x.addr_info||[]).find(x=>x.scope==='link'&&!x.tentative&&!x.dadfailed);if(!a)throw Error('OpenWrt USB link-local unavailable');fromAddress(a.local);return a.local;}
 policy(s){
  const rules=JSON.parse(this.run('ip',['-j','-6','rule','show'])),reserved=rules.filter(r=>Number(r.priority)===tableId);
  if(reserved.some(r=>!ownRule(r)||fromAddress(rulePrefix(r).split('/')[0])!==s.prefixHex+'0000000000000000'))throw Error('Reserved rule occupied');
  const routes=JSON.parse(this.run('ip',['-j','-6','route','show','table','all'])).filter(r=>Number(r.table)===tableId);
  if(routes.some(r=>String(r.protocol)!==String(protocol)))throw Error('Reserved route table occupied');
  const prefix=s.prefix;
  this.run('ip',['-6','route','replace','throw','fc00::/7','table','613','proto','196']);
  this.run('ip',['-6','route','replace','throw','fe80::/10','table','613','proto','196']);
  const lanStatus=JSON.parse(this.run('ubus',['call',`network.interface.${this.lan}`,'status']));
  const dev=lanStatus.l3_device||lanStatus.device;if(!/^[A-Za-z0-9_.-]{1,32}$/.test(dev||''))throw Error('LAN interface unavailable');
  if(this.mode==='lan')this.run('ip',['-6','route','replace',prefix,'dev',dev,'table','613','proto','196']);
  for(const addr of s.cpeAddresses)this.run('ip',['-6','route','replace',addr+'/128','via',s.usbLinkLocal,'dev',this.device,'table','613','proto','196']);
  this.run('ip',['-6','route','replace','default','via',s.usbLinkLocal,'dev',this.device,'table','613','proto','196']);
  if(!reserved.length)this.run('ip',['-6','rule','add','pref','613','from',prefix,'fwmark','0/0xff','lookup','613','protocol','196']);
 }
 async upstream(s,local){
  if(this.mode!=='lan')return;
  const lines=s.routes.split('\n'),owned=ownedRoutes(s.routes);
  for(const table of [181,200]){
   const r={prefix:s.prefix,table,local},key=routeKey(r),mine=owned.find(x=>routeKey(x)===key&&fromAddress(x.local)===fromAddress(local));
   const base=lines.some(l=>{try{return stockUsbRoute(l,s.prefix,table);}catch{return false;}});
   if(mine){this.routes.set(key,mine);continue;}
   if(!base)throw Error('Vendor USB prefix route unavailable; refusing mutation');
   // Do not replace the vendor route. Register ownership only after success.
   const cmd=`ip -6 route add ${s.prefix} via ${local} dev usb0 table ${table} proto 196 metric 665 && printf CPE6_ROUTE_OK`;
   if(!(await this.adb(cmd)).includes('CPE6_ROUTE_OK'))throw Error('CPE return route failed');
   this.routes.set(key,r);
  }
 }
 removePolicy(){
  const errors=[];let rules=[];
  try{rules=JSON.parse(this.run('ip',['-j','-6','rule','show']));}catch(e){errors.push(e);}
  for(const r of rules.filter(ownRule)){
   try{this.run('ip',['-6','rule','del','pref','613','from',rulePrefix(r),'fwmark','0/0xff','lookup','613','protocol','196']);}catch(e){errors.push(e);}
  }
  // Always try owned-route cleanup, even if rule inspection/deletion failed.
  let owned=true;
  try{owned=JSON.parse(this.run('ip',['-j','-6','route','show','table','all'])).some(r=>Number(r.table)===tableId&&String(r.protocol)===String(protocol));}catch(e){errors.push(e);}
  if(owned)try{this.run('ip',['-6','route','flush','table','613','proto','196']);}catch(e){errors.push(e);}
  return errors;
 }
 async removeUpstream(){
  const errors=[];
  for(const [key,r] of this.routes){
   try{
    // A successful shell transport alone is not a successful route deletion.
    const out=await this.adb(`ip -6 route del ${r.prefix} via ${r.local} dev usb0 table ${r.table} proto 196 metric 665 2>/dev/null; ip -6 route show table ${r.table} && printf '\\nCPE6_ROUTES_OK\\n'`);
    if(!out.includes('CPE6_ROUTES_OK'))throw Error('CPE route absence could not be confirmed');
    if(ownedRoutes(out,r.table).some(x=>routeKey(x)===key&&fromAddress(x.local)===fromAddress(r.local)))throw Error('CPE owned return route remains');
    this.routes.delete(key);
   }catch(e){errors.push(e);/* Keep the ledger for another bounded retry. */}
  }
  return errors;
 }
 async down(reason,block=this.blockIPv4()){
  const errors=[];
  for(const action of [()=>this.gate(block,true),()=>this.lanGate(false),()=>this.notify(withdraw(this.interfaceName,this.device))]){try{action();}catch(e){errors.push(e);}}
  errors.push(...this.removePolicy());this.current=null;this.lastHealth=0;errors.push(...await this.removeUpstream());
  this.status(errors.length?'cleanup-pending':'offline',reason);return errors.length===0;
 }
 async tick(){
  this.firewall();
  let s;try{s=await this.sense();}catch{this.lastTrustedQuota=null;await this.down('quota-unavailable');return;}
  this.lastTrustedQuota=trustedQuota(s?.quota);
  for(const r of ownedRoutes(s?.routes))this.routes.set(routeKey(r),r);
  if(!this.lastTrustedQuota){await this.down('quota-unavailable',true);return;}
  if(this.lastTrustedQuota.blocked){await this.down('quota-exceeded',true);return;}
  if(!this.recovered){
   // The full UDX snapshot survives process kill -9 through protocol ownership.
   if(!await this.down('restart-recovery',false))return;
   this.recovered=true;
   // This pre-cleanup snapshot must not re-adopt routes just deleted above.
   s=withoutOwned(s);
  }
  if(!s.prefix||!s.prefixHex||!s.usbLinkLocal||!s.hasDefault){await this.down('cellular-ipv6-unavailable',false);return;}
  if(this.current&&this.current.prefix!==s.prefix){if(!await this.down('prefix-transition',false))return;s=withoutOwned(s);this.lastHealth=0;}
  if(this.routes.size&&!this.current){if((await this.removeUpstream()).length){this.status('cleanup-pending','old-return-route');return;}s=withoutOwned(s);}
  if(Date.now()-this.lastHealth>=this.healthInterval*1000){
   const result=await this.adb('ping6 -I sipa_eth0 -c 1 -W 3 2400:3200::1 >/dev/null 2>&1 && printf CPE6_HEALTH_OK');
   if(!result.includes('CPE6_HEALTH_OK')){await this.down('ipv6-health-failed',false);return;}
   this.lastHealth=Date.now();
  }
  const local=this.localLink();await this.upstream(s,local);
  // Install the owned policy before netifd publishes a globally routable IP.
  this.policy(s);this.current=s;this.notify(update(this.interfaceName,this.device,s,{lan:this.mode==='lan',lifetime:this.lifetime}));
  this.lanGate(true);this.gate(false,false);this.status('online','native-ipv6');
 }
 async fail(reason='runtime-error'){await this.down(reason,this.blockIPv4());}
 async stop(){this.stopping=true;await this.down('stopped',this.blockIPv4());}
}
if(import.meta.url===`file://${process.argv[1]}`){
 const [interfaceName,device,host,port,lan,mode,interval,lifetime]=process.argv.slice(2);
 const c=new Controller({interfaceName,device,host,port:Number(port||5555),lan,mode,interval:Number(interval||15),lifetime:Number(lifetime||180)});
 c.acquireLock();let stop=false;for(const signal of ['SIGTERM','SIGINT','SIGHUP'])process.on(signal,()=>{stop=true;c.stopping=true;});
 try{
  while(!stop){try{await c.tick();}catch(e){try{await c.fail();}catch{}console.error('cpe5g-ipv6:',e.message);}for(let n=0;n<c.interval&&!stop;n++)await delay(1000);}
 }finally{try{await c.stop();}finally{c.releaseLock();}}
}
