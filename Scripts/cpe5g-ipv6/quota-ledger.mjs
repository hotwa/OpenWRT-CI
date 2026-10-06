// Persist cellular usage on OpenWrt; never modify modem counters or billing rows.
import fs from 'node:fs';
import path from 'node:path';
const decimal=x=>typeof x==='string'&&/^(0|[1-9][0-9]*)$/.test(x)&&x.length<=30;
const uuid=x=>typeof x==='string'&&/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(x);
export function counters(raw){
 const rows=Object.fromEntries(String(raw).trim().split('\n').map(l=>l.split('|')));
 if(!uuid(rows.boot)||!decimal(rows.rx)||!decimal(rows.tx))throw Error('Cellular kernel counters unavailable');
 return {boot:rows.boot,rx:rows.rx,tx:rows.tx};
}
function valid(state){
 return state?.version===1&&uuid(state.boot)&&decimal(state.rx)&&decimal(state.tx)&&decimal(state.used);
}
export function advance(previous,sample,vendorUsed){
 if(!uuid(sample?.boot)||!decimal(sample.rx)||!decimal(sample.tx)||!decimal(vendorUsed))throw Error('Invalid quota accounting sample');
 const rx=BigInt(sample.rx),tx=BigInt(sample.tx);
 let used;
 // Start a new, explicitly separate native accounting period. Vendor totals
 // may contain disputed history; importing them would undo a user's clear.
 if(previous===null)used=rx+tx;
 else{
  if(!valid(previous))throw Error('Invalid persistent quota ledger');
  if(previous.boot===sample.boot){
   if(rx<BigInt(previous.rx)||tx<BigInt(previous.tx))throw Error('Cellular counters regressed within one boot');
   used=BigInt(previous.used)+rx-BigInt(previous.rx)+tx-BigInt(previous.tx);
  }else used=BigInt(previous.used)+rx+tx;
 }
 return {version:1,...sample,used:used.toString()};
}
function safeDirectory(dir){
 const s=fs.lstatSync(dir);
 if(!s.isDirectory()||s.isSymbolicLink()||s.uid!==0||(s.mode&0o022))throw Error('Unsafe quota directory');
}
export class QuotaLedger{
 constructor({directory='/data/cpe5g-quota',mounts=()=>fs.readFileSync('/proc/mounts','utf8')}={}){this.directory=directory;this.mounts=mounts;}
 account(quota,sample){
  if(!quota||typeof quota.enabled!=='boolean'||!decimal(quota.limit)||!decimal(quota.used))throw Error('Invalid modem quota');
  if(!this.mounts().split('\n').some(l=>{const p=l.split(' ');return p[1]==='/data'&&p[0].startsWith('/dev/')&&['ext4','f2fs'].includes(p[2])&&p[3]?.split(',').includes('rw');}))throw Error('Quota persistence requires writable eMMC');
  safeDirectory(path.dirname(this.directory));
  try{fs.mkdirSync(this.directory,{mode:0o700});}catch(e){if(e.code!=='EEXIST')throw e;}
  safeDirectory(this.directory);
  const file=path.join(this.directory,'ledger.json');let previous=null;
  try{
   const s=fs.lstatSync(file);
   if(!s.isFile()||s.isSymbolicLink()||s.uid!==0||(s.mode&0o777)!==0o600||s.nlink!==1||s.size>4096)throw Error('Unsafe quota ledger');
   const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
   try{previous=JSON.parse(fs.readFileSync(fd,'utf8'));}finally{fs.closeSync(fd);}
  }catch(e){if(e.code!=='ENOENT')throw e;}
  const next=advance(previous,sample,quota.used);
  if(JSON.stringify(previous)!==JSON.stringify(next)){
   const temporary=file+'.'+process.pid+'.new';
   const fd=fs.openSync(temporary,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
   try{fs.writeFileSync(fd,JSON.stringify(next)+'\n');fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
   try{fs.renameSync(temporary,file);const dir=fs.openSync(this.directory,fs.constants.O_RDONLY);try{fs.fsyncSync(dir);}finally{fs.closeSync(dir);}}
   catch(e){try{fs.unlinkSync(temporary);}catch{}throw e;}
  }
  return {...quota,vendor_used:quota.used,used:next.used,source:'emmc-cellular-counters',blocked:quota.enabled&&(BigInt(quota.limit)===0n||BigInt(next.used)>=BigInt(quota.limit))};
 }
}
