// Native Lucky ACME mapping hook. CLI inputs and the trust store are fixed;
// constructor overrides exist only for isolated local fixture tests.
import fsDefault from 'node:fs';
import {createHash,createPrivateKey,createPublicKey,randomBytes,X509Certificate} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

export const originHostname='cpe.lucky.jmsu.top';
export const originSni='cpe-origin.jmsu.top';
export const certificatePaths=Object.freeze({
 sourceChain:'/etc/lucky/cert-sync/cpe5g-acme/cpe5g-origin.crt',
 sourceKey:'/etc/lucky/cert-sync/cpe5g-acme/cpe5g-origin.key',
 current:'/etc/lucky/cert-sync/cpe5g-origin/current',
 policy:'/etc/cpe5g/public-origin.json',
 manifest:'/etc/cpe5g-lucky/public-management.json',
 ready:'/var/run/cpe5g-lucky/public-ready.json',
 journal:'/etc/lucky/cert-sync/cpe5g-origin/.deploy-journal',
 restoreJournal:'/etc/cpe5g-lucky/.restore-journal',
 lock:'/etc/lucky/cert-sync/cpe5g-origin/.deploy-lock'
});
const minimumValidity=72*60*60*1000;
const message='CPE origin certificate deployment unavailable';
const unavailable=()=>new Error(message);
const hash=value=>createHash('sha256').update(value).digest('hex');
const hex=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
export const certificatePinFilename='certificate-pin.json';
const active=new Set();
const random=()=>randomBytes(12).toString('hex');
function certificates(pem){
 const pattern=/-----BEGIN CERTIFICATE-----\r?\n[\s\S]+?-----END CERTIFICATE-----/g;
 const blocks=pem.match(pattern);
 if(!blocks?.length||blocks.length>8||pem.replace(pattern,'').trim())throw unavailable();
 return blocks.map(block=>new X509Certificate(block));
}
function pair(chain,key,{now,san=true,validity=false}={}){
 const certs=certificates(chain),privateKey=createPrivateKey(key);
 if(certs[0].ca||!certs[0].publicKey.export({type:'spki',format:'der'}).equals(
  createPublicKey(privateKey).export({type:'spki',format:'der'})))throw unavailable();
 if(san&&certs[0].checkHost(originSni,{subject:'never',wildcards:false})!==originSni)throw unavailable();
 if(validity){
  if(!Number.isSafeInteger(now)||now<0)throw unavailable();
  for(let i=0;i<certs.length-1;i++){
   if(!certs[i+1].ca||!certs[i].checkIssued(certs[i+1])||!certs[i].verify(certs[i+1].publicKey))throw unavailable();
  }
  for(const cert of certs){
   const start=Date.parse(cert.validFrom),end=Date.parse(cert.validTo);
   if(!Number.isFinite(start)||!Number.isFinite(end)||start>now||end-now<minimumValidity)throw unavailable();
  }
 }
 return {certs,pin:hash(certs[0].raw)};
}
function validatePolicy(raw){
 if(!object(raw)||raw.enabled!==true||raw.hostname!==originHostname||raw.source_policy!=='mtls'||
  !hex(raw.client_ca_sha256)||('server_cert_sha256' in raw&&!hex(raw.server_cert_sha256)))throw unavailable();
 return raw;
}
function validatePin(raw,actualPin){
 if(!object(raw)||Object.keys(raw).sort().join(',')!=='hostname,origin_sni,server_cert_sha256,version'||
  raw.version!==1||raw.hostname!==originHostname||raw.origin_sni!==originSni||
  !hex(raw.server_cert_sha256)||(actualPin!==undefined&&raw.server_cert_sha256!==actualPin))throw unavailable();
 return raw;
}
function validateManifest(raw){
 if(!object(raw)||raw.version!==1||raw.hostname!==originHostname||raw.origin_sni!==originSni)throw unavailable();
 return raw;
}

export class OriginCertificateDeployer {
 constructor({fs=fsDefault,paths=certificatePaths,caFile,rootBoundary='/',now=Date.now,
  run=(bin,args)=>execFileSync(bin,args,{encoding:'utf8',timeout:10000,maxBuffer:131072,
   stdio:['ignore','pipe','pipe'],env:{PATH:'/usr/sbin:/usr/bin:/sbin:/bin',LANG:'C',LC_ALL:'C'}}),
  checkpoint=()=>{}}={}){
  this.fs=fs;this.paths=paths;this.caFile=caFile;this.rootBoundary=resolve(rootBoundary);
  this.now=now;this.run=run;this.checkpoint=checkpoint;
 }
 // O_NOFOLLOW alone protects only the final component. Every parent must
 // also be root-controlled, including the directory used for atomic renames.
 directory(file,{create=false}={}){
  const fs=this.fs,boundary=this.rootBoundary,target=resolve(file);
  if(target!==boundary&&!target.startsWith(boundary==='/'?'/':boundary+'/'))throw unavailable();
  const directories=[];let at=target;
  while(true){directories.push(at);if(at===boundary)break;const next=dirname(at);if(next===at)throw unavailable();at=next;}
  for(const dir of directories.reverse()){
   if(create){try{fs.mkdirSync(dir,{mode:0o700});}catch(e){if(e.code!=='EEXIST')throw e;}}
   const stat=fs.lstatSync(dir);
   if(!stat.isDirectory()||stat.isSymbolicLink()||stat.uid!==0||(stat.mode&0o022))throw unavailable();
  }
 }
 read(file,max=131072){
  const fs=this.fs;this.directory(dirname(file));
  const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK);
  try{
   const s=fs.fstatSync(fd);
   if(!s.isFile()||s.uid!==0||(s.mode&0o022)||s.size<1||s.size>max)throw unavailable();
   const bytes=fs.readFileSync(fd);
   if(bytes.length>max||bytes.length!==s.size)throw unavailable();
   return bytes;
  }finally{fs.closeSync(fd);}
 }
 syncDirectory(dir){const fd=this.fs.openSync(dir,this.fs.constants.O_RDONLY|this.fs.constants.O_DIRECTORY);try{this.fs.fsyncSync(fd);}finally{this.fs.closeSync(fd);}}
 write(file,bytes){
  const fs=this.fs;this.directory(dirname(file));
  const temporary=file+'.'+random();let fd;
  try{
   fd=fs.openSync(temporary,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
   fs.writeFileSync(fd,bytes);fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
   fs.renameSync(temporary,file);this.syncDirectory(dirname(file));
  }finally{if(fd!==undefined)fs.closeSync(fd);try{fs.unlinkSync(temporary);}catch(e){if(e.code!=='ENOENT')throw e;}}
 }
 removeReady(){
  const runtime=dirname(this.paths.ready),fs=this.fs;
  fs.mkdirSync(runtime,{recursive:true,mode:0o700});
  const canonical=fs.realpathSync(runtime),boundary=this.rootBoundary;
  const runtimeRoots=boundary==='/'?['/tmp','/run']:[join(boundary,'tmp'),join(boundary,'run')];
  // OpenWrt deliberately aliases /var to the root-owned sticky /tmp mount.
  // Only this readiness path may traverse those fixed runtime aliases.
  const allowed=runtimeRoots.some(root=>canonical.startsWith(root+'/'));
  if(!allowed){this.directory(runtime);}else{
   let at=resolve(runtime);
   while(true){
    const stat=fs.lstatSync(at);
    if(stat.uid!==0)throw unavailable();
    if(stat.isSymbolicLink()){
     const resolved=fs.realpathSync(at);
     if(!runtimeRoots.some(root=>resolved===root||resolved.startsWith(root+'/')))throw unavailable();
     const destination=fs.lstatSync(resolved);
     if(!destination.isDirectory()||destination.uid!==0||((destination.mode&0o022)&&
      !((destination.mode&0o1000)&&runtimeRoots.includes(resolved))))throw unavailable();
    }else if(!stat.isDirectory()||((stat.mode&0o022)&&!((stat.mode&0o1000)&&runtimeRoots.includes(fs.realpathSync(at)))))throw unavailable();
    if(at===boundary)break;const next=dirname(at);if(next===at)throw unavailable();at=next;
   }
   const stat=fs.lstatSync(canonical);
   if(!stat.isDirectory()||stat.isSymbolicLink()||stat.uid!==0||(stat.mode&0o022))throw unavailable();
  }
  try{this.fs.unlinkSync(this.paths.ready);}catch(e){if(e.code!=='ENOENT')throw e;}
  this.syncDirectory(dirname(this.paths.ready));
 }
 exists(file){try{this.fs.lstatSync(file);return true;}catch(e){if(e.code==='ENOENT')return false;throw e;}}
 procIdentity(pid){
  if(!Number.isSafeInteger(pid)||pid<=0)throw unavailable();
  const text=this.fs.readFileSync('/proc/'+pid+'/stat','utf8');
  const start=text.slice(text.lastIndexOf(')')+2).split(' ')[19];
  if(!/^\d+$/.test(start))throw unavailable();
  return start;
 }
 acquire(){
  const fs=this.fs,p=this.paths;this.directory(dirname(p.lock),{create:true});
  try{fs.mkdirSync(p.lock,{mode:0o700});}catch(e){if(e.code!=='EEXIST')throw e;}
  this.directory(p.lock);
  const token=random(),owner={pid:process.pid,start:this.procIdentity(process.pid),token,ticket:null};
  const stage=p.lock+'.stage-'+token,lease=join(p.lock,token);fs.mkdirSync(stage,{mode:0o700});
  let published=false;
  const participants=()=>{
   const result=[];
   for(const name of fs.readdirSync(p.lock)){
    if(!/^[a-f0-9]{24}$/.test(name))throw unavailable();
    const dir=join(p.lock,name);let candidate;
    try{this.directory(dir);candidate=JSON.parse(this.read(join(dir,'owner.json'),4096));}
    catch(e){if(e.code==='ENOENT')continue;throw e;}
    if(!object(candidate)||candidate.token!==name||!Number.isSafeInteger(candidate.pid)||candidate.pid<=0||
     typeof candidate.start!=='string'||!/^\d+$/.test(candidate.start)||
     (candidate.ticket!==null&&(typeof candidate.ticket!=='string'||!/^[1-9]\d{0,39}$/.test(candidate.ticket))))throw unavailable();
    let alive;try{alive=this.procIdentity(candidate.pid)===candidate.start;}catch(e){if(e.code!=='ENOENT'&&e.code!=='ESRCH')throw e;alive=false;}
    if(!alive){fs.rmSync(dir,{recursive:true,force:true});continue;}
    result.push(candidate);
   }
   return result;
  };
  const release=()=>{
   if(published){
    const current=JSON.parse(this.read(join(lease,'owner.json'),4096));
    if(current.token!==token||current.pid!==owner.pid||current.start!==owner.start)throw unavailable();
    fs.rmSync(lease,{recursive:true});published=false;
   }
   try{fs.rmdirSync(p.lock);}catch(e){if(!['ENOENT','ENOTEMPTY','EEXIST'].includes(e.code))throw e;}
   this.syncDirectory(dirname(p.lock));
  };
  try{
   // A filesystem bakery lock uses uniquely named, atomically published
   // choosing records. Dead leases are removable by process starttime;
   // there is no reclaim guard that can remain stuck after a crash.
   this.write(join(stage,'owner.json'),JSON.stringify(owner));this.syncDirectory(stage);
   fs.renameSync(stage,lease);published=true;this.syncDirectory(p.lock);
   const peers=participants().filter(candidate=>candidate.token!==token);
   const largest=peers.reduce((max,candidate)=>candidate.ticket!==null&&BigInt(candidate.ticket)>max?BigInt(candidate.ticket):max,0n);
   owner.ticket=(largest+1n).toString();this.write(join(lease,'owner.json'),JSON.stringify(owner));
   for(const candidate of participants()){
    if(candidate.token===token)continue;
    if(candidate.ticket===null||BigInt(candidate.ticket)<BigInt(owner.ticket)||
     (candidate.ticket===owner.ticket&&candidate.token<token))throw unavailable();
   }
   return release;
  }catch(error){release();throw error;}
  finally{if(this.exists(stage))fs.rmSync(stage,{recursive:true});}
 }
 currentPair(){
  const fs=this.fs,p=this.paths;
  if(!this.exists(p.current))return null;
  this.directory(p.current);
  const entries=fs.readdirSync(p.current).sort();
  if(entries.length===0)return null;
  const layout=entries.join(',');
  if(layout!=='fullchain.pem,privkey.pem'&&layout!==certificatePinFilename+',fullchain.pem,privkey.pem')throw unavailable();
  const chain=this.read(join(p.current,'fullchain.pem')),key=this.read(join(p.current,'privkey.pem'));
  const actualPin=pair(chain.toString('utf8'),key.toString('utf8'),{san:false}).pin;
  let certificatePin=null;
  if(entries.includes(certificatePinFilename)){
   certificatePin=this.read(join(p.current,certificatePinFilename),4096);
   validatePin(JSON.parse(certificatePin),actualPin);
  }
  return {chain,key,certificatePin};
 }
 createPair(dir,material){
  this.fs.mkdirSync(dir,{mode:0o700});
  this.write(join(dir,'fullchain.pem'),material.chain);this.write(join(dir,'privkey.pem'),material.key);
  if(material.certificatePin)this.write(join(dir,certificatePinFilename),material.certificatePin);
  this.syncDirectory(dir);
 }
 trustStore(){
  const candidates=this.caFile?[this.caFile]:['/etc/ssl/cert.pem','/etc/ssl/certs/ca-certificates.crt'];
  for(const file of candidates){
   if(!this.exists(file))continue;
   // System CA aliases may be symlinks, but their resolved file and all
   // containing directories must still be root-controlled.
   this.directory(dirname(file));const resolved=this.fs.realpathSync(file);this.read(resolved,4*1024*1024);
   return resolved;
  }
  throw unavailable();
 }
 verify(material,stage,now){
  const {certs,pin}=pair(material.chain.toString('utf8'),material.key.toString('utf8'),{now,validity:true});
  this.write(join(stage,'leaf.pem'),certs[0].toString());
  const args=['verify','-purpose','sslserver','-verify_hostname',originSni,'-attime',String(Math.floor(now/1000)),
   '-no-CApath','-no-CAstore','-CAfile',this.trustStore()];
  if(certs.length>1){this.write(join(stage,'intermediates.pem'),certs.slice(1).map(cert=>cert.toString()).join('\n'));args.push('-untrusted',join(stage,'intermediates.pem'));}
  args.push(join(stage,'leaf.pem'));
  this.run('/usr/bin/openssl',args);
  return pin;
 }
 journal(){
  const dir=this.paths.journal;this.directory(dir);
  const raw=JSON.parse(this.read(join(dir,'transaction.json'),4096));
  if(!object(raw)||![1,2].includes(raw.version)||typeof raw.hadCurrent!=='boolean'||
   !hex(raw.nextChainHash)||!hex(raw.nextKeyHash)||
   (raw.hadCurrent&&(!hex(raw.oldChainHash)||!hex(raw.oldKeyHash))))throw unavailable();
  if(raw.version===1){
   // Older deployments journaled authorization policy. Verify those backups
   // for ownership, but never replay them over an administrator's policy.
   if(!hex(raw.policyHash)||!hex(raw.nextPolicyHash))throw unavailable();
   const policy=this.read(join(dir,'previous-policy.json'),65536);
   const nextPolicy=this.read(join(dir,'next-policy.json'),65536);
   if(hash(policy)!==raw.policyHash||hash(nextPolicy)!==raw.nextPolicyHash)throw unavailable();
   validatePolicy(JSON.parse(policy));validatePolicy(JSON.parse(nextPolicy));
  }else if(typeof raw.previousHasPin!=='boolean'||!hex(raw.nextPinHash)||
   (raw.previousHasPin&&(!raw.hadCurrent||!hex(raw.oldPinHash))))throw unavailable();
  let previous=null;
  if(raw.hadCurrent){
   previous={chain:this.read(join(dir,'previous','fullchain.pem')),key:this.read(join(dir,'previous','privkey.pem')),certificatePin:null};
   if(hash(previous.chain)!==raw.oldChainHash||hash(previous.key)!==raw.oldKeyHash)throw unavailable();
   const actualPin=pair(previous.chain.toString('utf8'),previous.key.toString('utf8'),{san:false}).pin;
   if(raw.version===2&&raw.previousHasPin){
    previous.certificatePin=this.read(join(dir,'previous',certificatePinFilename),4096);
    if(hash(previous.certificatePin)!==raw.oldPinHash)throw unavailable();
    validatePin(JSON.parse(previous.certificatePin),actualPin);
   }
  }
  return {raw,previous};
 }
 retireJournal(){
  const fs=this.fs,p=this.paths,garbage=p.journal+'.complete-'+random();
  fs.renameSync(p.journal,garbage);
  try{this.syncDirectory(dirname(p.journal));}catch(error){
   // If marker retirement is not durable, put the recovery gate back
   // before allowing the caller to roll back the transaction.
   fs.renameSync(garbage,p.journal);throw error;
  }
  // The active marker is gone only after commit/rollback is durable. A
  // crash during garbage cleanup cannot turn a partial journal into a gate.
  try{fs.rmSync(garbage,{recursive:true});}catch{/* Inert root-only backup; no public output. */}
 }
 recover(){
  const fs=this.fs,p=this.paths;
  if(!this.exists(p.journal))return false;
  this.removeReady();const {previous}=this.journal();
  let restore;
  if(previous){restore=join(p.journal,'restore-'+random());this.createPair(restore,previous);}
  if(this.exists(p.current)){this.directory(p.current);fs.renameSync(p.current,join(p.journal,'discard-'+random()));this.syncDirectory(dirname(p.current));this.syncDirectory(p.journal);}
  if(restore){fs.renameSync(restore,p.current);this.syncDirectory(dirname(p.current));this.syncDirectory(p.journal);}
  // Authorization is a separate administrator-owned file. Recovery never
  // writes it, so edits during any pair move/fsync remain byte-for-byte exact.
  this.checkpoint('rollback');this.retireJournal();
  return true;
 }
 deploy(){try{return this.perform();}catch{throw unavailable();}}
 perform(){
  const fs=this.fs,p=this.paths;
  if(active.has(p.lock))throw unavailable();active.add(p.lock);
  let release,stage,journalPublished=false;
  try{
   release=this.acquire();
   // The private restorer owns this journal and the same certificate pair.
   // A reclaimed dead lease must not let ACME change its recovery inputs.
   this.directory(dirname(p.restoreJournal));
   if(this.exists(p.restoreJournal))throw unavailable();
   this.recover();
   const policyBytes=this.read(p.policy,65536);validatePolicy(JSON.parse(policyBytes));
   const manifestBytes=this.read(p.manifest,65536);validateManifest(JSON.parse(manifestBytes));
   const material={chain:this.read(p.sourceChain),key:this.read(p.sourceKey)};
   const previous=this.currentPair();
   stage=p.journal+'.stage-'+random();fs.mkdirSync(stage,{mode:0o700});
   const pin=this.verify(material,stage,this.now());
   material.certificatePin=Buffer.from(JSON.stringify({version:1,hostname:originHostname,origin_sni:originSni,server_cert_sha256:pin},null,2)+'\n');
   // Commit certificate-owned pin bytes in the same directory transaction
   // as the verified pair. Never mutate administrator-owned authorization.
   if(previous)this.createPair(join(stage,'previous'),previous);
   this.createPair(join(stage,'next'),material);
   this.write(join(stage,'transaction.json'),JSON.stringify({version:2,hadCurrent:!!previous,previousHasPin:!!previous?.certificatePin,
    nextChainHash:hash(material.chain),nextKeyHash:hash(material.key),nextPinHash:hash(material.certificatePin),
    ...(previous?{oldChainHash:hash(previous.chain),oldKeyHash:hash(previous.key),
     ...(previous.certificatePin?{oldPinHash:hash(previous.certificatePin)}:{})}:{})}));
   this.syncDirectory(stage);
   if(!this.read(p.policy,65536).equals(policyBytes)||!this.read(p.manifest,65536).equals(manifestBytes))throw unavailable();
   const current=this.currentPair();
   if(!!current!==!!previous||(current&&(!current.chain.equals(previous.chain)||!current.key.equals(previous.key)||
    !!current.certificatePin!==!!previous.certificatePin||(current.certificatePin&&!current.certificatePin.equals(previous.certificatePin)))))throw unavailable();
   fs.renameSync(stage,p.journal);stage=undefined;journalPublished=true;this.syncDirectory(dirname(p.journal));
   this.removeReady();this.checkpoint('journal');
   if(previous){fs.renameSync(p.current,join(p.journal,'displaced'));this.syncDirectory(dirname(p.current));this.syncDirectory(p.journal);}
   this.checkpoint('old-pair-moved');
   fs.renameSync(join(p.journal,'next'),p.current);this.syncDirectory(dirname(p.current));this.syncDirectory(p.journal);this.checkpoint('pair');
   if(!this.read(p.policy,65536).equals(policyBytes)||!this.read(p.manifest,65536).equals(manifestBytes))throw unavailable();
   this.checkpoint('pin');
   const deployed=this.currentPair();
   if(!deployed||!deployed.chain.equals(material.chain)||!deployed.key.equals(material.key)||
    !deployed.certificatePin?.equals(material.certificatePin)||!this.read(p.policy,65536).equals(policyBytes)||
    !this.read(p.manifest,65536).equals(manifestBytes))throw unavailable();
   this.retireJournal();journalPublished=false;
   return {server_cert_sha256:pin};
  }catch{
   if(journalPublished){try{this.recover();journalPublished=false;}catch{/* Keep journal gate and durable backups for the next invocation. */}}
   throw unavailable();
  }finally{
   if(stage&&this.exists(stage)){try{fs.rmSync(stage,{recursive:true});}catch{}}
   try{release?.();}finally{active.delete(p.lock);}
  }
 }
}
export function deployOriginCertificate(options){try{return new OriginCertificateDeployer(options).deploy();}catch{throw unavailable();}}
export function certificateMain({stdout=()=>{},stderr=text=>process.stderr.write(text),deployer,...options}={}){
 try{if(!deployer&&process.argv.length>2)throw unavailable();(deployer??new OriginCertificateDeployer(options)).deploy();return 0;}
 catch{stderr(message+'\n');return 1;}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 // Environment variables and CLI arguments cannot redirect trusted paths,
 // trust anchors, or the expected SAN in production.
 process.exitCode=certificateMain();
}
