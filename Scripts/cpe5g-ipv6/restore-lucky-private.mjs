// Restore only missing CPE-owned files from the immutable private firmware.
// Existing Lucky tokens, LKCF files and administrator authorization are never
// replaced. Production paths and certificate trust cannot be redirected.
import fsDefault from 'node:fs';
import {createHash,createPrivateKey,createPublicKey,randomBytes,X509Certificate} from 'node:crypto';
import {dirname,join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {OriginCertificateDeployer,certificatePaths,originHostname,originSni} from './deploy-origin-certificate.mjs';
import {validateManifest,validateMaterials,validatePolicy} from './lucky-origin.mjs';
import {validateManagedSeed} from './reconcile-lucky-managed.mjs';

export const privateRestorePaths=Object.freeze({
 policy:'/etc/cpe5g/public-origin.json',manifest:'/etc/cpe5g-lucky/public-management.json',
 managed:'/etc/cpe5g-lucky/managed-native.json',clientCa:'/etc/cpe5g-lucky/tls/client-ca.pem',
 healthCert:'/etc/cpe5g-lucky/tls/health-client.crt',healthKey:'/etc/cpe5g-lucky/tls/health-client.key',
 current:certificatePaths.current,journal:'/etc/cpe5g-lucky/.restore-journal',lock:certificatePaths.lock,
 deployJournal:certificatePaths.journal,
 ready:certificatePaths.ready,rom:'/rom'
});
const pairNames=['certificate-pin.json','fullchain.pem','privkey.pem'];
const fileNames=['manifest','managed','clientCa','healthCert','healthKey'];
const maximum=65536,message='CPE private Lucky restoration unavailable';
const unavailable=()=>new Error(message);
const hash=value=>createHash('sha256').update(value).digest('hex');
const random=()=>randomBytes(12).toString('hex');
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const json=bytes=>JSON.parse(bytes.toString('utf8'));
const manifestFields=['version','hostname','origin_sni','origin_header_secret','username','password'];
const certificateLifetime=72*3600000;
function certificates(pem){
 const pattern=/-----BEGIN CERTIFICATE-----\r?\n[\s\S]+?-----END CERTIFICATE-----/g,blocks=pem.match(pattern);
 if(!blocks?.length||blocks.length>8||pem.replace(pattern,'').trim())throw unavailable();
 return blocks.map(block=>new X509Certificate(block));
}

export class LuckyPrivateRestorer {
 constructor({fs=fsDefault,paths=privateRestorePaths,rootBoundary='/',caFile,now=Date.now,run,checkpoint=()=>{}}={}){
  Object.assign(this,{fs,paths,rootBoundary:resolve(rootBoundary),now,checkpoint});
  if(!paths.policy.endsWith(privateRestorePaths.policy))throw unavailable();
  this.deviceRoot=paths.policy.slice(0,-privateRestorePaths.policy.length);
  if(Object.entries(privateRestorePaths).some(([name,path])=>paths[name]!==this.deviceRoot+path))throw unavailable();
  this.certificate=new OriginCertificateDeployer({fs,paths:{...certificatePaths,...paths},rootBoundary,caFile,now,...(run?{run}:{})});
  this.created=[];
 }
 directory(file,create=false){
  if(!create)return this.certificate.directory(file);
  const target=resolve(file),boundary=this.rootBoundary;
  if(target!==boundary&&!target.startsWith(boundary==='/'?'/':boundary+'/'))throw unavailable();
  const parts=[];let at=target;
  while(true){parts.push(at);if(at===boundary)break;at=dirname(at);}
  for(const path of parts.reverse()){
   try{this.fs.mkdirSync(path,{mode:0o700});this.created.push({path,stat:this.fs.lstatSync(path)});}
   catch(e){if(e.code!=='EEXIST')throw e;}
   this.certificate.directory(path);
  }
 }
 optional(file,{allowLinked=false}={}){
  let fd;
  try{
   this.directory(dirname(file));
   fd=this.fs.openSync(file,this.fs.constants.O_RDONLY|this.fs.constants.O_NOFOLLOW|this.fs.constants.O_NONBLOCK);
   const stat=this.fs.fstatSync(fd);
   if(!stat.isFile()||stat.uid!==0||(stat.mode&0o077)||stat.nlink<1||stat.nlink>(allowLinked?2:1)||stat.size<1||stat.size>maximum)throw unavailable();
   const bytes=this.fs.readFileSync(fd);
   if(bytes.length!==stat.size||bytes.length>maximum)throw unavailable();
   return {bytes,stat};
  }catch(e){if(e.code==='ENOENT')return null;throw e;}
  finally{if(fd!==undefined)this.fs.closeSync(fd);}
 }
 read(file){const value=this.optional(file);if(!value)throw unavailable();return value;}
 same(file,snapshot,{allowLinked=false}={}){
  const current=this.optional(file,{allowLinked});
  return snapshot===null?current===null:current!==null&&current.stat.dev===snapshot.stat.dev&&current.stat.ino===snapshot.stat.ino&&current.bytes.equals(snapshot.bytes);
 }
 romPath(file){
  const relative=file.slice(this.deviceRoot.length);
  if(!relative.startsWith('/etc/'))throw unavailable();
  return join(this.paths.rom,relative);
 }
 pair(directory){
  let stat;
  try{stat=this.fs.lstatSync(directory);}catch(e){if(e.code==='ENOENT')return null;throw e;}
  this.directory(directory);
  const entries=this.fs.readdirSync(directory).sort();
  if(entries.some(name=>!pairNames.includes(name)))throw unavailable();
  return {stat,entries,files:Object.fromEntries(entries.map(name=>[name,this.read(join(directory,name))]))};
 }
 samePair(snapshot){
  const current=this.pair(this.paths.current);
  return snapshot===null?current===null:current!==null&&current.stat.dev===snapshot.stat.dev&&current.stat.ino===snapshot.stat.ino&&
   JSON.stringify(current.entries)===JSON.stringify(snapshot.entries)&&snapshot.entries.every(name=>this.same(join(this.paths.current,name),snapshot.files[name]));
 }
 material(files,pair){return {chain:pair.files['fullchain.pem'].bytes.toString('utf8'),key:pair.files['privkey.pem'].bytes.toString('utf8'),
  clientCa:files.clientCa.bytes.toString('utf8'),healthCert:files.healthCert.bytes.toString('utf8'),healthKey:files.healthKey.bytes.toString('utf8')};}
 verify(files,pair,rawPolicy,stage,at=this.now()){
  const pin=json(pair.files['certificate-pin.json'].bytes);
  if(!object(pin)||Object.keys(pin).sort().join(',')!=='hostname,origin_sni,server_cert_sha256,version')throw unavailable();
  const policy=validatePolicy(rawPolicy,pin),material=this.material(files,pair);
  validateMaterials(material,policy,at);
  if(!new X509Certificate(material.healthCert).keyUsage?.includes('1.3.6.1.5.5.7.3.2'))throw unavailable();
  const actual=this.certificate.verify({chain:Buffer.from(material.chain),key:Buffer.from(material.key)},stage,at);
  if(actual!==pin.server_cert_sha256)throw unavailable();
 }
 verifyRom(seed,stage){
  // A retained renewed certificate can outlive the image's original pair.
  // Authenticate the immutable seed during its common valid period, then
  // separately require all material actually installed to be valid now.
  const material=this.material(seed.files,seed.pair),certs=[material.chain,material.clientCa,material.healthCert]
   .flatMap(pem=>pem.match(/-----BEGIN CERTIFICATE-----\r?\n[\s\S]+?-----END CERTIFICATE-----/g)??[]).map(pem=>new X509Certificate(pem));
  const first=Math.max(...certs.map(cert=>Date.parse(cert.validFrom))),last=Math.min(...certs.map(cert=>Date.parse(cert.validTo)-72*3600000-1)),
   at=Math.min(this.now(),last);
  if(!Number.isSafeInteger(at)||at<first)throw unavailable();
  this.verify(seed.files,seed.pair,seed.policy,stage,at);
 }
 verifyClients(files,rawPolicy,pin){
  const policy=validatePolicy(rawPolicy,pin),ca=certificates(files.clientCa.bytes.toString('utf8')),
   health=certificates(files.healthCert.bytes.toString('utf8')),at=this.now();
  if(ca.length!==1||health.length!==1||!ca[0].ca||health[0].ca||
   !health[0].checkIssued(ca[0])||!health[0].verify(ca[0].publicKey)||
   !health[0].keyUsage?.includes('1.3.6.1.5.5.7.3.2')||hash(ca[0].raw)!==policy.client_ca_sha256)throw unavailable();
  const privateKey=createPrivateKey(files.healthKey.bytes);
  if(!health[0].publicKey.export({type:'spki',format:'der'}).equals(createPublicKey(privateKey).export({type:'spki',format:'der'})))throw unavailable();
  for(const cert of [...ca,...health]){
   const first=Date.parse(cert.validFrom),last=Date.parse(cert.validTo);
   if(!Number.isSafeInteger(at)||!Number.isFinite(first)||!Number.isFinite(last)||at<first||last-at<=certificateLifetime)throw unavailable();
  }
 }
 serverFresh(pair,rawPolicy,stage,{allowMissingPin=false}={}){
  if(!pair?.files['fullchain.pem']||!pair.files['privkey.pem'])throw unavailable();
  const certs=certificates(pair.files['fullchain.pem'].bytes.toString('utf8')),now=this.now(),
   first=Math.max(...certs.map(cert=>Date.parse(cert.validFrom))),
   last=Math.min(...certs.map(cert=>Date.parse(cert.validTo)-certificateLifetime-1)),at=Math.min(now,last);
  // Renewal is allowed only for an authenticated old certificate. Future,
  // malformed, short-total-lifetime or untrusted material stays an error.
  if(!Number.isSafeInteger(now)||now<first||!Number.isSafeInteger(at)||at<first)throw unavailable();
  const actual=this.certificate.verify({chain:pair.files['fullchain.pem'].bytes,key:pair.files['privkey.pem'].bytes},stage,at);
  let pin;
  if(pair.files['certificate-pin.json'])pin=json(pair.files['certificate-pin.json'].bytes);
  else if(allowMissingPin)pin={version:1,hostname:originHostname,origin_sni:originSni,server_cert_sha256:actual};
  else throw unavailable();
  if(!object(pin)||Object.keys(pin).sort().join(',')!=='hostname,origin_sni,server_cert_sha256,version'||pin.server_cert_sha256!==actual)throw unavailable();
  validatePolicy(rawPolicy,pin);
  return certs.every(cert=>Date.parse(cert.validTo)-now>certificateLifetime);
 }
 selectedMaterials(files,pair,policy,seed,stage){
  this.verifyClients(files,policy,json(seed.pair.files['certificate-pin.json'].bytes));
  const complete=pair?.entries.length===3;
  if(complete){
   const pendingCertificate=!this.serverFresh(pair,policy,stage);
   if(!pendingCertificate)this.verify(files,pair,policy,stage);
   return {pendingCertificate,replacePair:false};
  }
  if(this.serverFresh(seed.pair,policy,stage)){
   this.verify(files,seed.pair,policy,stage);return {pendingCertificate:false,replacePair:true};
  }
  if(pair?.entries.length){
   // A historical complete key+chain can await a new owned pin, but a lone
   // component cannot establish authenticity and must not mask tampering.
   if(pair.entries.join(',')!=='fullchain.pem,privkey.pem')throw unavailable();
   this.serverFresh(pair,policy,stage,{allowMissingPin:true});
  }
  return {pendingCertificate:true,replacePair:false};
 }
 seed(){
  const paths=this.paths,romPolicy=this.optional(this.romPath(paths.policy)),
   files=Object.fromEntries(fileNames.map(name=>[name,this.optional(this.romPath(paths[name]))])),
   pair=this.pair(this.romPath(paths.current));
  const privatePresent=Object.values(files).some(Boolean)||pair!==null;
  if(!privatePresent&&(!romPolicy||(object(json(romPolicy.bytes))&&json(romPolicy.bytes).enabled===false&&!json(romPolicy.bytes).hostname)))return null;
  if(!romPolicy||Object.values(files).some(value=>!value)||!pair||pair.entries.length!==3)throw unavailable();
  const policy=json(romPolicy.bytes),manifest=validateManifest(json(files.manifest.bytes));
  validateManagedSeed(json(files.managed.bytes),manifest);
  return {policy,policyFile:romPolicy,manifest,files,pair};
 }
 installExclusive(source,target,linked){
  this.directory(dirname(target),true);
  const snapshot=this.read(source);
  this.fs.linkSync(source,target);linked(snapshot);
  this.fs.unlinkSync(source);this.certificate.syncDirectory(dirname(target));return snapshot;
 }
 stageFile(stage,name,bytes){const file=join(stage,name);this.certificate.write(file,bytes);return file;}
 identity(snapshot){return {dev:snapshot.stat.dev,ino:snapshot.stat.ino,size:snapshot.bytes.length,sha256:hash(snapshot.bytes)};}
 pairIdentity(pair){return pair===null?null:{dev:pair.stat.dev,ino:pair.stat.ino,
  files:Object.fromEntries(pair.entries.map(name=>[name,this.identity(pair.files[name])]))};}
 fileMatches(snapshot,identity){return snapshot!==null&&snapshot.stat.dev===identity.dev&&snapshot.stat.ino===identity.ino&&
  snapshot.bytes.length===identity.size&&hash(snapshot.bytes)===identity.sha256;}
 pairMatches(pair,identity){return pair!==null&&identity!==null&&pair.stat.dev===identity.dev&&pair.stat.ino===identity.ino&&
  JSON.stringify(pair.entries)===JSON.stringify(Object.keys(identity.files).sort())&&pair.entries.every(name=>this.fileMatches(pair.files[name],identity.files[name]));}
 recoveryRecord(){
  const raw=json(this.read(join(this.paths.journal,'restore-transaction.json')).bytes);
  const file=value=>object(value)&&Object.keys(value).sort().join(',')==='dev,ino,sha256,size'&&
   Number.isSafeInteger(value.dev)&&value.dev>=0&&Number.isSafeInteger(value.ino)&&value.ino>0&&
   Number.isSafeInteger(value.size)&&value.size>0&&value.size<=maximum&&typeof value.sha256==='string'&&/^[a-f0-9]{64}$/.test(value.sha256);
  const pair=value=>object(value)&&Object.keys(value).sort().join(',')==='dev,files,ino'&&
   Number.isSafeInteger(value.dev)&&value.dev>=0&&Number.isSafeInteger(value.ino)&&value.ino>0&&object(value.files)&&
   Object.entries(value.files).every(([name,data])=>pairNames.includes(name)&&file(data));
  if(!object(raw)||Object.keys(raw).sort().join(',')!=='files,hostname,kind,next_pair,origin_sni,policy,previous_pair,version'||
   raw.version!==2||raw.kind!=='cpe5g-private-restore'||raw.hostname!==originHostname||raw.origin_sni!==originSni||
   !object(raw.files)||!Object.entries(raw.files).every(([name,data])=>fileNames.includes(name)&&file(data))||
   (raw.policy!==null&&!file(raw.policy))||(raw.previous_pair!==null&&!pair(raw.previous_pair))||
   (raw.next_pair!==null&&(!pair(raw.next_pair)||Object.keys(raw.next_pair.files).sort().join(',')!==pairNames.join(','))))throw unavailable();
  return raw;
 }
 recover(){
  const fs=this.fs,p=this.paths;
  if(!this.certificate.exists(p.journal))return false;
  this.directory(p.journal);const record=this.recoveryRecord();
  if(record.next_pair===null&&record.previous_pair!==null)throw unavailable();
  this.certificate.removeReady();this.checkpoint('rollback');
  if(record.next_pair!==null){
   let current=this.pair(p.current),previous=this.pair(join(p.journal,'previous-pair')),
    discarded=this.pair(join(p.journal,'discard-pair'));
   if(discarded&&!this.pairMatches(discarded,record.next_pair))throw unavailable();
   if(previous&&!this.pairMatches(previous,record.previous_pair))throw unavailable();
   if(this.pairMatches(current,record.next_pair)){
    if(discarded)throw unavailable();
    fs.renameSync(p.current,join(p.journal,'discard-pair'));this.certificate.syncDirectory(dirname(p.current));
    this.certificate.syncDirectory(p.journal);current=null;this.checkpoint('recovery-pair-removed');
   }else if(current&&!this.pairMatches(current,record.previous_pair))throw unavailable();
   if(record.previous_pair!==null){
    if(previous){
     if(current)throw unavailable();
     fs.renameSync(join(p.journal,'previous-pair'),p.current);this.certificate.syncDirectory(dirname(p.current));
     this.certificate.syncDirectory(p.journal);this.checkpoint('recovery-pair-restored');
    }else if(!this.pairMatches(current,record.previous_pair))throw unavailable();
   }else if(previous||current)throw unavailable();
  }
  if(record.policy!==null){
   const policy=this.optional(p.policy,{allowLinked:true});
   // Authorization belongs to the administrator. An edited or replaced
   // policy survives recovery exactly, including an in-place disable.
   if(this.fileMatches(policy,record.policy)){
    fs.unlinkSync(p.policy);this.certificate.syncDirectory(dirname(p.policy));
   }
  }
  for(const [name,identity] of Object.entries(record.files).reverse()){
   const existing=this.optional(p[name],{allowLinked:true});
   if(!existing)continue;
   if(!this.fileMatches(existing,identity))throw unavailable();
   fs.unlinkSync(p[name]);this.certificate.syncDirectory(dirname(p[name]));this.checkpoint('recovery-file:'+name);
  }
  this.certificate.retireJournal();return true;
 }
 cleanCreated(){
  for(const {path,stat} of this.created.reverse())try{
   const current=this.fs.lstatSync(path);
   if(current.dev===stat.dev&&current.ino===stat.ino)this.fs.rmdirSync(path);
  }catch{/* Existing or populated administrator directories remain intact. */}
  this.created=[];
 }
 restore(){try{return this.perform();}catch{throw unavailable();}}
 perform(){
  const fs=this.fs,p=this.paths;
  // Recover an interrupted generation before consulting ROM or respecting
  // an administrator disable. Recovery never needs a fresh certificate.
  if(this.certificate.exists(p.journal)){
   const release=this.certificate.acquire();
   try{if(this.certificate.exists(p.deployJournal))throw unavailable();this.recover();}
   finally{release();}
  }
  const policyBefore=this.optional(p.policy);
  if(policyBefore){
   const policy=json(policyBefore.bytes);
   if(object(policy)&&policy.enabled===false&&policy.hostname===originHostname)return {status:'disabled',restored:0};
  }
  const seed=this.seed();if(!seed)return {status:'no-private-seed',restored:0};
  let release,stage,published=false,policyInstalled=null;
  try{
   this.directory(dirname(p.journal),true);release=this.certificate.acquire();
   if(this.certificate.exists(p.journal)||this.certificate.exists(p.deployJournal))throw unavailable();
   stage=p.journal+'.private-stage-'+random();fs.mkdirSync(stage,{mode:0o700});
   this.verifyRom(seed,stage);
   const currentFiles=Object.fromEntries(fileNames.map(name=>[name,this.optional(p[name])])),currentPair=this.pair(p.current);
   if(currentFiles.manifest){
    const manifest=validateManifest(json(currentFiles.manifest.bytes));
    if(manifestFields.some(name=>manifest[name]!==seed.manifest[name]))throw unavailable();
   }
   if(currentFiles.managed){
    const raw=json(currentFiles.managed.bytes),managed=validateManagedSeed(raw,{...seed.manifest,
     lucky_rule_key:raw?.rule?.RuleKey,ddns_task_key:raw?.ddns?.TaskKey,ssl_task_key:raw?.ssl?.Key}),original=json(seed.files.managed.bytes);
    if(managed.ddns.DNS.ID!==original.ddns.DNS.ID||managed.ddns.DNS.Secret!==original.ddns.DNS.Secret)throw unavailable();
   }
   let policy=seed.policy,keepDefault=false;
   if(policyBefore){
    policy=json(policyBefore.bytes);
    keepDefault=object(policy)&&Object.keys(policy).length===1&&policy.enabled===false;
    if(keepDefault)policy=seed.policy;
    else if(policy.enabled!==true||policy.hostname!==originHostname||policy.client_ca_sha256!==seed.policy.client_ca_sha256)throw unavailable();
   }
   const files=Object.fromEntries(fileNames.map(name=>[name,currentFiles[name]??seed.files[name]]));
   const {pendingCertificate,replacePair}=this.selectedMaterials(files,currentPair,policy,seed,stage),
    pending=pendingCertificate?{pendingCertificate:true}:{};
   const missing=fileNames.filter(name=>!currentFiles[name]);
   if(!missing.length&&!replacePair&&policyBefore){
    if(pendingCertificate)this.certificate.removeReady();
    return {status:keepDefault?'disabled-default':'unchanged',restored:0,...pending};
   }
   for(const name of missing)this.stageFile(stage,name,seed.files[name].bytes);
   if(!policyBefore)this.stageFile(stage,'policy',seed.policyFile.bytes);
   if(replacePair){
    const next=join(stage,'next');fs.mkdirSync(next,{mode:0o700});
    for(const name of pairNames)this.stageFile(next,name,seed.pair.files[name].bytes);
    this.certificate.syncDirectory(next);
   }
   this.stageFile(stage,'restore-transaction.json',JSON.stringify({version:2,kind:'cpe5g-private-restore',hostname:originHostname,origin_sni:originSni,
    files:Object.fromEntries(missing.map(name=>[name,this.identity(this.read(join(stage,name)))])),
    policy:policyBefore?null:this.identity(this.read(join(stage,'policy'))),
    next_pair:replacePair?this.pairIdentity(this.pair(join(stage,'next'))):null,previous_pair:replacePair?this.pairIdentity(currentPair):null}));
   this.certificate.syncDirectory(stage);
   if(!this.same(p.policy,policyBefore)||fileNames.some(name=>!this.same(p[name],currentFiles[name]))||!this.samePair(currentPair))throw unavailable();
   fs.renameSync(stage,p.journal);stage=null;published=true;this.certificate.syncDirectory(dirname(p.journal));
   this.certificate.removeReady();this.checkpoint('journal');
   for(const name of missing){
    this.installExclusive(join(p.journal,name),p[name],()=>{});this.checkpoint('file:'+name);
   }
   if(replacePair){
    if(!this.samePair(currentPair))throw unavailable();
    if(currentPair){fs.renameSync(p.current,join(p.journal,'previous-pair'));this.certificate.syncDirectory(dirname(p.current));this.certificate.syncDirectory(p.journal);}
    this.checkpoint('old-pair-moved');
    fs.renameSync(join(p.journal,'next'),p.current);this.certificate.syncDirectory(dirname(p.current));this.certificate.syncDirectory(p.journal);this.checkpoint('pair');
   }
   // link() atomically publishes a fully written policy only when no policy
   // exists. A concurrent administrator's policy causes EEXIST and rollback.
   if(!policyBefore){this.installExclusive(join(p.journal,'policy'),p.policy,snapshot=>{policyInstalled=snapshot;});this.checkpoint('policy');}
   else if(!this.same(p.policy,policyBefore))throw unavailable();
   const finalFiles=Object.fromEntries(fileNames.map(name=>[name,this.read(p[name])])),finalPair=this.pair(p.current);
   const final=this.selectedMaterials(finalFiles,finalPair,policy,seed,p.journal);
   if(final.pendingCertificate!==pendingCertificate||final.replacePair||(!replacePair&&!this.samePair(currentPair)))throw unavailable();
   if(fileNames.some(name=>!finalFiles[name].bytes.equals(files[name].bytes)))throw unavailable();
   if(!this.same(p.policy,policyBefore??policyInstalled))throw unavailable();
   this.certificate.retireJournal();published=false;
   return {status:keepDefault?'disabled-default':'restored',restored:missing.length+(replacePair?3:0)+(policyInstalled?1:0),...pending};
  }catch{
   if(published)try{this.recover();published=false;}
   catch{/* Keep the durable journal and backups; the next boot retries. */}
   throw unavailable();
  }finally{
   if(stage)try{fs.rmSync(stage,{recursive:true,force:true});}catch{}
   release?.();this.cleanCreated();
  }
 }
}
export function restoreLuckyPrivate(options){return new LuckyPrivateRestorer(options).restore();}
export function privateRestoreMain({restorer,stderr=text=>process.stderr.write(text),...options}={}){
 try{if(!restorer&&process.argv.length>2)throw unavailable();(restorer??new LuckyPrivateRestorer(options)).restore();return 0;}
 catch{stderr(message+'\n');return 1;}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href)process.exitCode=privateRestoreMain();
