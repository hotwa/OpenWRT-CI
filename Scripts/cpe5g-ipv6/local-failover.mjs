// mwan3 handles LAN policy marks; local sockets need a usable main-table
// default too. Retain a lower-priority WAN route for interface-bound probes.
import fs from 'node:fs';
import net from 'node:net';
import {execFileSync} from 'node:child_process';
const ledgerFile='/var/run/cpe5g-local-route.json';
const owned=r=>r.dst==='default'&&Number(r.protocol)===197&&Number(r.metric)===1000;
const same=(a,b)=>a.dev===b.dev&&a.gateway===b.gateway;
function valid(r){
 if(!r||r.dst!=='default'||!net.isIP(r.gateway)||net.isIP(r.gateway)!==4||!/^[a-zA-Z0-9_.-]{1,32}$/.test(r.dev)||Number(r.metric)!==10||!['static','dhcp'].includes(r.protocol))throw Error('WAN default route is not a managed candidate');
 if(r.prefsrc&&net.isIP(r.prefsrc)!==4)throw Error('invalid WAN source');
 if((r.flags||[]).some(f=>f!=='onlink'))throw Error('unsupported WAN route flags');
 return r;
}
function args(op,r,degraded=false){
 const a=['-4','route',op,'default','via',r.gateway,'dev',r.dev,'proto',degraded?'197':r.protocol,'metric',degraded?'1000':'10'];
 if(r.prefsrc)a.push('src',r.prefsrc);
 if((r.flags||[]).includes('onlink'))a.push('onlink');
 return a;
}
const defaultRun=(bin,a)=>execFileSync(bin,a,{encoding:'utf8',timeout:3000});
const status=n=>{try{return fs.readFileSync('/var/run/mwan3track/'+n+'/STATUS','utf8').trim();}catch{return 'unknown';}};
const getLedger=()=>{try{return JSON.parse(fs.readFileSync(ledgerFile,'utf8'));}catch(e){if(e.code==='ENOENT')return null;throw e;}};
const putLedger=r=>{fs.writeFileSync(ledgerFile+'.new',JSON.stringify(r),{mode:0o600});fs.renameSync(ledgerFile+'.new',ledgerFile);};
const delLedger=()=>fs.rmSync(ledgerFile,{force:true});
export function reconcile({run=defaultRun,readStatus=status,readLedger=getLedger,saveLedger=putLedger,clearLedger=delLedger}={}){
 const wan=JSON.parse(run('ubus',['call','network.interface.wan','status']));
 const rows=()=>JSON.parse(run('ip',['-j','-4','route','show','table','main']));
 let routes=rows(),ledger=readLedger();
 if(ledger)valid(ledger);
 const tagged=routes.filter(owned);
 if(tagged.some(r=>!ledger||!same(r,ledger)))throw Error('reserved local-failover route is foreign');
 const health=readStatus('wan');
 const gw=wan.route?.find(r=>r.target==='0.0.0.0'&&Number(r.mask)===0)?.nexthop;
 const dev=wan.l3_device||wan.device;
 const current=wan.up&&dev===ledger?.dev&&gw===ledger?.gateway;
 if(ledger&&!current){
  for(const r of tagged)run('ip',args('del',ledger,true));
  clearLedger();ledger=null;routes=rows();
 }
 if(!wan.up||!['online','offline'].includes(health))return;
 const original=routes.find(r=>r.dst==='default'&&r.dev===dev&&r.gateway===gw&&Number(r.metric)===10&&['static','dhcp'].includes(r.protocol));
 if(health==='offline'){
  if(readStatus('5G')!=='online'||(!original&&!ledger))return;
  const r=valid(original||ledger);
  if(ledger&&!same(r,ledger))throw Error('WAN route changed during failover');
  saveLedger(r); // Write ahead: a kill between route operations is recoverable.
  if(!routes.some(t=>owned(t)&&same(t,r)))run('ip',args('add',r,true));
  if(!rows().some(t=>owned(t)&&same(t,r)))throw Error('degraded WAN route was not installed');
  if(original)run('ip',args('del',r));
 }else if(ledger){
  if(!original){
   if(ledger.prefsrc&&!wan['ipv4-address']?.some(a=>a.address===ledger.prefsrc))throw Error('WAN source changed; waiting for netifd route');
   run('ip',args('add',ledger));
  }
  if(!rows().some(r=>r.dst==='default'&&same(r,ledger)&&Number(r.metric)===10))throw Error('primary WAN restoration is not confirmed');
  for(const r of rows().filter(r=>owned(r)&&same(r,ledger)))run('ip',args('del',ledger,true));
  clearLedger();
 }
}
