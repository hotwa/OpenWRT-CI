// This optional origin never admits a subnet or creates a lasting exception.
// Configuration comes only from local root-owned files, never from the web.
import fs from 'node:fs';
import net from 'node:net';
import {fromAddress,ipv6} from './model.mjs';
export const publicPort=18443,publicTimeout=45,publicMark=0x40000000;
export const configPath='/etc/cpe5g/public-origin.json';
export const readyPath='/var/run/cpe5g-lucky/public-ready.json';
export const certificateJournal='/etc/lucky/cert-sync/cpe5g-origin/.deploy-journal';
export const restoreJournal='/etc/cpe5g-lucky/.restore-journal';
export const certificatePinPath='/etc/lucky/cert-sync/cpe5g-origin/current/certificate-pin.json';
export function readRootJson(file){
 const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
 try{
  const stat=fs.fstatSync(fd);
  if(!stat.isFile()||stat.uid!==0||(stat.mode&0o022)||stat.size>65536)throw Error('Public origin file is not root-controlled');
  return JSON.parse(fs.readFileSync(fd,'utf8'));
 }finally{fs.closeSync(fd);}
}
export function sourcePrefix(value){
 if(typeof value!=='string')throw Error('Invalid public origin source');
 const parts=value.split('/'),bits=parts.length===1?128:Number(parts[1]);
 if(parts.length>2||(parts.length===2&&!/^\d{1,3}$/.test(parts[1]))||!Number.isInteger(bits)||bits<1||bits>128||net.isIP(parts[0])!==6)throw Error('Public origin requires explicit IPv6 sources; ::/0 is forbidden');
 const hex=fromAddress(parts[0]),shift=BigInt(128-bits),prefix=(BigInt('0x'+hex)>>shift)<<shift;
 return ipv6(prefix.toString(16).padStart(32,'0'))+'/'+bits;
}
export function publicConfig(raw,pin){
 if(!raw||raw.enabled!==true)return null;
 const host=raw.hostname;
 if(typeof host!=='string'||host.length>253||!host.includes('.')||!host.split('.').every(x=>/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(x))||net.isIP(host))throw Error('Public origin hostname must be one FQDN');
 const source_policy=raw.source_policy===undefined?'allowlist':raw.source_policy;
 if(!['allowlist','mtls'].includes(source_policy))throw Error('Invalid public origin source policy');
 if(source_policy==='mtls'){
  if(raw.allowed_sources!==undefined&&(!Array.isArray(raw.allowed_sources)||raw.allowed_sources.length))throw Error('mTLS source policy cannot contain an IP allowlist');
  if(pin!==undefined&&(!pin||pin.version!==1||pin.hostname!=='cpe.lucky.jmsu.top'||host.toLowerCase()!==pin.hostname||pin.origin_sni!=='cpe-origin.jmsu.top'))throw Error('Public origin certificate pin identity mismatch');
  const serverPin=pin===undefined?raw.server_cert_sha256:pin.server_cert_sha256;
  if(![raw.client_ca_sha256,serverPin].every(x=>typeof x==='string'&&/^[a-f0-9]{64}$/i.test(x)))throw Error('mTLS origin requires pinned client CA and server certificate');
  return {hostname:host.toLowerCase(),source_policy,sources:[],client_ca_sha256:raw.client_ca_sha256.toLowerCase(),server_cert_sha256:serverPin.toLowerCase()};
 }
 if(!Array.isArray(raw.allowed_sources)||!raw.allowed_sources.length||raw.allowed_sources.length>256)throw Error('Public origin requires a nonempty approved source list');
 return {hostname:host.toLowerCase(),source_policy,sources:[...new Set(raw.allowed_sources.map(sourcePrefix))]};
}
export function readyFor(raw,config,address,now=Date.now()){
 try{
  if(!(raw?.ready===true&&raw.port===publicPort&&raw.hostname?.toLowerCase()===config.hostname&&fromAddress(raw.address)===fromAddress(address)&&Number.isSafeInteger(raw.updated)&&now-raw.updated<=30000&&raw.updated-now<=5000&&(raw.source_policy===undefined?'allowlist':raw.source_policy)===config.source_policy))return false;
  if(config.source_policy==='mtls')return raw.mtls_verified===true&&raw.origin_header_verified===true&&typeof raw.client_ca_sha256==='string'&&typeof raw.server_cert_sha256==='string'&&raw.client_ca_sha256.toLowerCase()===config.client_ca_sha256&&raw.server_cert_sha256.toLowerCase()===config.server_cert_sha256;
  return true;
 }catch{return false;}
}
export function installedAddress(rows,address,device='usb0'){
 const validLife=value=>value==='forever'||(Number.isFinite(Number(value))&&Number(value)>0);
 return rows.some(row=>row.ifname===device&&(row.addr_info||[]).some(a=>{
  try{
   const flags=Array.isArray(a.flags)?a.flags:[];
   return a.family==='inet6'&&a.scope==='global'&&Number(a.prefixlen)===128&&fromAddress(a.local)===fromAddress(address)&&!['tentative','dadfailed','deprecated'].some(flag=>a[flag]||flags.includes(flag))&&validLife(a.preferred_life_time??a.preferred_lft)&&validLife(a.valid_life_time??a.valid_lft);
  }catch{return false;}
 }));
}
export function publicSetBatch(address=null,sources=[],source_policy='allowlist'){
 if(!['allowlist','mtls'].includes(source_policy))throw Error('Invalid public origin source policy');
 const grant=!address?'':source_policy==='mtls'?`add element inet cpe6_guard public_mtls_address { ${address} timeout ${publicTimeout}s }\n`:`add element inet cpe6_guard public_sources { ${sources.join(', ')} }\nadd element inet cpe6_guard public_address { ${address} timeout ${publicTimeout}s }\n`;
 return `flush set inet cpe6_guard public_sources\nflush set inet cpe6_guard public_address\nflush set inet cpe6_guard public_mtls_address\n${grant}`;
}
export function publicQuota(q){
 if(!q||typeof q.enabled!=='boolean'||q.blocked!==false||typeof q.limit!=='string'||typeof q.used!=='string'||!/^\d+$/.test(q.limit)||!/^\d+$/.test(q.used))return false;
 return !q.enabled||(BigInt(q.limit)>0n&&BigInt(q.used)<BigInt(q.limit));
}
export class PublicAccess {
 constructor({run,device='usb0',readJson=readRootJson,configFile=configPath,readyFile=readyPath,pinFile=certificatePinPath,now=Date.now,deploying=()=>[certificateJournal,restoreJournal].some(file=>fs.existsSync(file))}={}){Object.assign(this,{run,device,readJson,configFile,readyFile,pinFile,now,deploying});}
 clear(){this.run('nft',['-f','-'],publicSetBatch());return false;}
 refresh({address,online,quota}){
  if(!online||!publicQuota(quota)||this.device!=='usb0'||this.deploying())return this.clear();
  let config;
  try{
   const raw=this.readJson(this.configFile);
   let pin;
   if(raw?.enabled===true&&raw.source_policy==='mtls'){
    pin=this.readJson(this.pinFile);if(pin===undefined)throw Error('Public origin certificate pin unavailable');
   }
   config=publicConfig(raw,pin);
   if(!config||!readyFor(this.readJson(this.readyFile),config,address,this.now()))return this.clear();
   const rows=JSON.parse(this.run('ip',['-j','-6','addr','show','dev',this.device]));
   if(!installedAddress(rows,address,this.device)||this.deploying())return this.clear();
  }catch{return this.clear();}
  this.run('nft',['-f','-'],publicSetBatch(address,config.sources,config.source_policy));return true;
 }
}
export function guardDefinition(device,version=4,legacy=false){
 const permit=version>=4?'meta mark set meta mark | 0x40000000 accept':'accept';
 const publicRules=version>=2?` set public_sources { type ipv6_addr; flags interval; auto-merge; }
 set public_address { type ipv6_addr; size 1; timeout 45s; gc-interval 5s; }
 ${version>=3?'set public_mtls_address { type ipv6_addr; size 1; timeout 45s; gc-interval 5s; }\n ':''}chain public_origin {
  iifname @ipv6_blocked counter drop
  ip6 saddr @public_sources ip6 daddr @public_address ${permit}
  ${version>=3?`ip6 daddr @public_mtls_address ${permit}\n  `:''}counter drop
 }
`:'';
 return `table inet cpe6_guard {
 comment "cpe5g-ipv6-v${version}"
 set blocked { type ifname; elements = { "${device}" }; }
 ${legacy?'':`set ipv6_blocked { type ifname; elements = { "${device}" }; }`}
${publicRules} chain input { type filter hook input priority -15; policy accept;
  ${version>=2?`iifname "${device}" meta nfproto ipv6 tcp dport ${publicPort} jump public_origin\n  `:''}iifname "${device}" meta nfproto ipv6 ct state established,related accept
  iifname "${device}" ip6 saddr fe80::/10 accept
  iifname "${device}" meta l4proto ipv6-icmp accept
  iifname "${device}" meta nfproto ipv6 udp dport 41641 accept
  iifname "${device}" meta nfproto ipv6 counter drop
 }
 chain output { type filter hook output priority -15; policy accept;
  oifname "${device}" ip daddr 192.168.66.0/24 accept
  oifname "${device}" ip daddr 255.255.255.255 udp sport 68 udp dport 67 accept
  oifname "${device}" ip6 daddr fe80::/10 accept
  oifname "${device}" ip6 daddr ff02::/16 meta l4proto ipv6-icmp icmpv6 type { 133, 134, 135, 136 } accept
  ${legacy?'':`meta nfproto ipv6 oifname @ipv6_blocked counter drop\n  `}oifname @blocked counter drop
 }
 chain forward { type filter hook forward priority -15; policy accept;
  oifname "${device}" ip daddr 192.168.66.0/24 accept
  oifname "${device}" ip6 daddr fe80::/10 accept
  ${legacy?'':`meta nfproto ipv6 oifname @ipv6_blocked counter drop\n  `}oifname @blocked counter drop
 }
}\n`;
}
function canonicalGuard(text){
 return text.replace(/set\s+(\w+)\s*\{((?:[^{}]|\{[^{}]*\})*)\}/g,(all,name,body)=>{
  // nft 1.1.6 annotates an occupied sized set as `size 1 # count 1`.
  // This generated line comment is not part of the owned set schema.
  // Normalize only the two known singleton sets, not arbitrary comments.
  if(['public_address','public_mtls_address'].includes(name))body=body.replace(/(^|\n)([ \t]*size[ \t]+1)[ \t]+#[ \t]+count[ \t]+[01][ \t]*(?=\r?\n|$)/g,'$1$2');
  return `set ${name} {${body.replace(/elements\s*=\s*\{[^{}]*\}\s*;?/g,'')}}`;
 })
  .replace(/counter packets \d+ bytes \d+/g,'counter')
  .replace(/meta l4proto ipv6-icmp (?=icmpv6 type)/g,'')
  .replaceAll('nd-router-solicit','133').replaceAll('nd-router-advert','134').replaceAll('nd-neighbor-solicit','135').replaceAll('nd-neighbor-advert','136')
  .replace(/"(?:\\.|[^"\\])*"|[;\s]+/g,token=>token.startsWith('"')?token:'').trim();
}
// A marker alone is insufficient: foreign rules, chains and set layouts
// cannot be erased by a table migration, even when they copy our comment.
export function guardVersion(text,device){
 // Dynamic quota sets may only contain the one interface we manage.
 for(const match of text.matchAll(/set\s+(blocked|ipv6_blocked)\s*\{((?:[^{}]|\{[^{}]*\})*)\}/g)){
  const elements=match[2].match(/elements\s*=\s*\{([^{}]*)\}/)?.[1]?.trim();
  if(elements&&elements!==`"${device}"`)return null;
 }
 for(const [version,legacy] of [[4,false],[3,false],[2,false],[1,false],[1,true]])if(canonicalGuard(text)===canonicalGuard(guardDefinition(device,version,legacy)))return version;
 return null;
}
