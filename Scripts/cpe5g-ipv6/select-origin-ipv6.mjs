// Local-only DDNS input: emit only the controller-owned, installed /128.
import fsDefault from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {fromAddress,ipv6,nativeAddress} from './model.mjs';

export const statusPath='/var/run/cpe5g-ipv6/status.json';
const unavailable=()=>new Error('Native IPv6 origin is unavailable');
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
function addressHex(value){
 if(typeof value!=='string'||value.includes('%')||value.includes('.'))throw unavailable();
 return fromAddress(value).toLowerCase();
}
function counter(value){
 // The controller serializes exact counters as decimal strings, not lossy
 // JSON numbers. Recompute the cap decision instead of trusting blocked.
 if(typeof value!=='string'||!/^\d{1,40}$/.test(value))throw unavailable();
 return BigInt(value);
}
function currentStatus(raw,now){
 if(!object(raw)||raw.phase!=='online'||!Number.isSafeInteger(now)||now<0||
    !Number.isSafeInteger(raw.updated)||raw.updated<0||now-raw.updated>45000||raw.updated-now>5000)throw unavailable();
 const q=raw.quota;
 if(!object(q)||typeof q.enabled!=='boolean'||typeof q.blocked!=='boolean')throw unavailable();
 const limit=counter(q.limit),used=counter(q.used);
 const blocked=q.enabled&&(limit===0n||used>=limit);
 if(q.blocked!==blocked||blocked)throw unavailable();
 if(typeof raw.prefix!=='string')throw unavailable();
 const parts=raw.prefix.split('/');
 if(parts.length!==2||parts[1]!=='64')throw unavailable();
 const prefix=addressHex(parts[0]);
 if(!/^[23]/.test(prefix)||!prefix.endsWith('0000000000000000'))throw unavailable();
 const expected=addressHex(nativeAddress(prefix.slice(0,16)));
 if(addressHex(raw.address)!==expected)throw unavailable();
 return {prefix,address:expected};
}
function lifetime(value){
 return value==='forever'||(typeof value==='number'&&Number.isSafeInteger(value)&&value>0)||
  (typeof value==='string'&&/^\d{1,20}$/.test(value)&&BigInt(value)>0n);
}
function installed(rows,address){
 if(!Array.isArray(rows)||rows.length!==1||!object(rows[0])||rows[0].ifname!=='usb0'||!Array.isArray(rows[0].addr_info))throw unavailable();
 const matches=rows[0].addr_info.filter(info=>{
  if(!object(info))return false;
  try{return addressHex(info.local)===address;}catch{return false;}
 });
 if(matches.length!==1)throw unavailable();
 const info=matches[0];
 if(info.family!=='inet6'||info.scope!=='global'||info.prefixlen!==128||
    (info.flags!==undefined&&(!Array.isArray(info.flags)||!info.flags.every(f=>typeof f==='string'))))throw unavailable();
 for(const flag of ['tentative','dadfailed','deprecated']){
  if((info[flag]!==undefined&&info[flag]!==false)||(info.flags||[]).includes(flag))throw unavailable();
 }
 if(!lifetime(info.preferred_life_time??info.preferred_lft)||!lifetime(info.valid_life_time??info.valid_lft))throw unavailable();
}
function parse(text){
 if(typeof text!=='string'||text.length>131072)throw unavailable();
 return JSON.parse(text);
}

export function selectOriginIpv6({fs=fsDefault,run=(bin,args)=>execFileSync(bin,args,{
 encoding:'utf8',timeout:1500,maxBuffer:131072,stdio:['pipe','pipe','pipe']
}),now=Date.now,file=statusPath}={}){
 try{
  const before=currentStatus(parse(fs.readFileSync(file,'utf8')),now());
  const rows=parse(run('ip',['-j','-6','addr','show','dev','usb0']));
  installed(rows,before.address);
  // Prefix renewal, quota closure or shutdown during the kernel query must
  // not publish the address from a superseded online snapshot.
  const after=currentStatus(parse(fs.readFileSync(file,'utf8')),now());
  if(before.prefix!==after.prefix||before.address!==after.address)throw unavailable();
  return ipv6(after.address);
 }catch{throw unavailable();}
}

export function selectorMain({stdout=text=>process.stdout.write(text),stderr=text=>process.stderr.write(text),...options}={}){
 try{stdout(selectOriginIpv6(options)+'\n');return 0;}
 catch{stderr('Native IPv6 origin is unavailable\n');return 1;}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 process.exitCode=selectorMain();
}
