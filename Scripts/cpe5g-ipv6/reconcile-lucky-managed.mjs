// CPE-owned Lucky entries only. Run after restore has reached a terminal
// decision; encrypted LKCF restoration must not erase the firmware's entries.
import fsDefault from 'node:fs';
import {execFileSync} from 'node:child_process';
import {dirname,resolve} from 'node:path';
import {randomBytes} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {validateManifest} from './lucky-origin.mjs';
import {OriginCertificateDeployer} from './deploy-origin-certificate.mjs';

export const managedHostname='cpe.lucky.jmsu.top';
export const managedOrigin='cpe-origin.jmsu.top';
export const managedPaths=Object.freeze({
 seed:'/etc/cpe5g-lucky/managed-native.json',
 romSeed:'/rom/etc/cpe5g-lucky/managed-native.json',
 romManifest:'/rom/etc/cpe5g-lucky/public-management.json',
 manifest:'/etc/cpe5g-lucky/public-management.json',
 token:'/etc/lucky/cert-sync/lucky.token',
 policy:'/etc/cpe5g/public-origin.json',
 registry:'/etc/cpe5g-lucky/managed-native-keys.json',
 lock:'/etc/cpe5g-lucky/.managed-native-lock',
 restoreService:'/etc/init.d/wrtbak-firstboot-auto',
 restoreGate:'/root/wrtbak/firstboot/gate.json'
});
export const managedNames=Object.freeze({rule:'managed-cpe-udx-public-backend',ddns:'managed-cpe5g-origin-ipv6',ssl:'cpe5g-origin'});
const maximum=65536;
const active=new Set();
const failure='CPE managed Lucky reconciliation unavailable';
const unavailable=()=>new Error(failure);
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const id=value=>typeof value==='string'&&/^[A-Za-z0-9_-]{1,128}$/.test(value);
const secret=value=>typeof value==='string'&&value.length>=8&&value.length<=512&&!/[\x00-\x20\x7f]/.test(value);
const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const clone=value=>JSON.parse(JSON.stringify(value));
const terminal=new Set(['already_done','restored','no_backup','failed_final','disabled']);

export function readManagedFile(fs,file,{rootBoundary='/',privateFile=true,max=maximum}={}){
 const boundary=resolve(rootBoundary);let at=dirname(resolve(file));
 if(at!==boundary&&!at.startsWith(boundary==='/'?'/':boundary+'/'))throw unavailable();
 while(true){
  const s=fs.lstatSync(at);
  if(!s.isDirectory()||s.isSymbolicLink()||s.uid!==0||(s.mode&0o022))throw unavailable();
  if(at===boundary)break;const next=dirname(at);if(next===at)throw unavailable();at=next;
 }
 const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK);
 try{
  const s=fs.fstatSync(fd);
  if(!s.isFile()||s.uid!==0||(s.mode&(privateFile?0o077:0o022))||s.size<1||s.size>max)throw unavailable();
  const bytes=fs.readFileSync(fd);
  if(bytes.length!==s.size||bytes.length>max)throw unavailable();
  return bytes.toString('utf8');
 }finally{fs.closeSync(fd);}
}
function validRule(rule,{manifest,seed=false}={}){
 if(!object(rule)||!id(rule.RuleKey)||typeof rule.Enable!=='boolean'||rule.Network!=='tcp4'||
  rule.ListenIP!=='127.0.0.1'||rule.ListenPort!==16801||rule.EnableTLS!==false||rule.Http3!==false||
  rule.AutoOptionsFirewall===true||!object(rule.DefaultProxy)||rule.DefaultProxy.WebServiceType!=='close'||
  (rule.DefaultProxy.Locations?.length??0)!==0||!Array.isArray(rule.ProxyList)||rule.ProxyList.length!==1)throw unavailable();
 const child=rule.ProxyList[0];
 if(!object(child)||!id(child.Key)||typeof child.Enable!=='boolean'||child.WebServiceType!=='reverseproxy'||
  !equal(child.Domains,[managedHostname])||!equal(child.Locations,['http://192.168.66.1:6677'])||
  child.EnableBasicAuth!==true||(child.WebAuth??child.OtherParams?.WebAuth)!==true||typeof child.BasicAuthUserList!=='string'||
  child.BasicAuthUserList.length<25||!object(child.OtherParams)||child.OtherParams.WebAuth!==true||
  (child.BasicAuthRegConf!==undefined&&child.BasicAuthRegConf!=='')||
  child.OtherParams.BasicAuthRegConf!==''||child.OtherParams.AutoOptionsFirewall!==false||
  child.CacheEnabled!==false||child.UseRuleGlobalAuthSettings===true||child.NginxConf||child.ProxyType||child.ProxyAddr||
  child.OtherParams.HttpClientProxyType||child.OtherParams.HttpClientProxyAddr)throw unavailable();
 if(seed&&child.BasicAuthUserList!==manifest.username+':'+manifest.password)throw unavailable();
 return rule;
}
function validDns(task){
 if(!object(task)||!id(task.TaskKey)||typeof task.Enable!=='boolean'||task.TaskType!=='IPv6'||
  task.V4QueryIPEnable!==false||task.V6QueryIPEnable!==true||task.V6QueryIPType!=='command'||
  task.V6GetIPScript!=='/usr/libexec/cpe5g-ipv6/select-origin-ipv6'||!object(task.DNS)||
  task.DNS.Name!=='alidns'||task.DNS.CallAPINetwork!=='tcp4'||task.DNS.HttpClientProxyType||
  !secret(task.DNS.ID)||!secret(task.DNS.Secret)||!Array.isArray(task.Records)||task.Records.length!==1)throw unavailable();
 const record=task.Records[0],data=record?.SyncRecordData;
 if(!object(record)||!object(data)||data.type!=='AAAA'||data.fullDomainName!==managedOrigin||
  data.ipv6Address!=='{ipv6Addr}'||task.WebhookEnable===true||task.GlobalWebhook===true)throw unavailable();
 return task;
}
function validSsl(info,{mapping=true}={}){
 if(!object(info)||!id(info.Key)||typeof info.Enable!=='boolean'||info.AddFrom!=='acme'||
  !object(info.ExtParams)||info.ExtParams.acmeDNSServer!=='alidns'||
  !equal(info.ExtParams.acmeDomains,[managedOrigin])||!secret(info.ExtParams.acmeDNSID)||
  !secret(info.ExtParams.acmeDNSSecret)||info.ExtParams.acmeCADirURL!=='https://acme-v02.api.letsencrypt.org/directory'||
  info.ExtParams.acmeProxy||info.AllSyncClient===true||(info.SyncClientList?.length??0)!==0)throw unavailable();
 if(mapping&&(info.MappingToPath!==true||info.MappingPath!=='/etc/lucky/cert-sync/cpe5g-acme'||
  info.MappingChangeScript!=='/usr/libexec/cpe5g-ipv6/deploy-origin-certificate'))throw unavailable();
 return info;
}
export function validateManagedSeed(raw,manifest){
 validateManifest(manifest);
 if(!object(raw)||raw.version!==1||raw.domain_suffix!=='jmsu.top'||!id(manifest.ssl_task_key))throw unavailable();
 validRule(raw.rule,{manifest,seed:true});validDns(raw.ddns);validSsl(raw.ssl);
 if(raw.rule.RuleKey!==manifest.lucky_rule_key||raw.ddns.TaskKey!==manifest.ddns_task_key||raw.ssl.Key!==manifest.ssl_task_key||
  raw.rule.RuleName!==managedNames.rule||raw.ddns.TaskName!==managedNames.ddns||raw.ssl.Remark!==managedNames.ssl||
  raw.ddns.DNS.ID!==raw.ssl.ExtParams.acmeDNSID||raw.ddns.DNS.Secret!==raw.ssl.ExtParams.acmeDNSSecret)throw unavailable();
 return clone(raw);
}
export function restoreTerminal({fs=fsDefault,paths=managedPaths,rootBoundary='/',
 run=(binary,args)=>execFileSync(binary,args,{encoding:'utf8',timeout:3000,stdio:['ignore','pipe','pipe']})}={}){
 // Retained UCI alone is not an operative restore service. This is common
 // when upgrading from a firmware whose optional wrtbak runtime was removed.
 try{
  const service=fs.lstatSync(paths.restoreService);
  if(!service.isFile()||service.isSymbolicLink()||service.uid!==0||(service.mode&0o022))throw unavailable();
  if(!(service.mode&0o111))return true;
 }catch(e){if(e.code==='ENOENT')return true;throw unavailable();}
 try{run('/bin/sh',['-c','command -v wrtbak >/dev/null 2>&1']);}
 catch(e){if(e.status===1)return true;throw unavailable();}
 let enabled;
 try{enabled=run('/sbin/uci',['-q','get','wrtbak.main.firstboot_auto_enabled']).trim();}
 catch(error){if(error.status===1)return true;throw unavailable();}
 if(!['1','true','yes','on'].includes(enabled))return true;
 try{
  const gate=JSON.parse(readManagedFile(fs,paths.restoreGate,{rootBoundary,privateFile:false,max:4096}));
  return object(gate)&&terminal.has(gate.state);
 }catch{return false;}
}
export function loadManagedSeed({fs=fsDefault,paths=managedPaths,rootBoundary='/'}={}){
 let file=paths.seed;
 // A private ROM generation wins over an older /etc seed restored by
 // sysupgrade/wrtbak. Never fall back from a present malformed ROM seed.
 try{fs.lstatSync(paths.romSeed);file=paths.romSeed;}catch(e){if(e.code!=='ENOENT')throw unavailable();}
 let raw;
 try{raw=JSON.parse(readManagedFile(fs,file,{rootBoundary}));}
 catch(e){
  if(e.code==='ENOENT'&&file===paths.seed){
   // Generic firmware may omit the optional feature. A configured private
   // manifest without its mandatory native seed is incomplete and stays closed.
   try{fs.lstatSync(paths.manifest);}catch(missing){if(missing.code==='ENOENT')return null;}
  }
  throw unavailable();
 }

 const manifest=JSON.parse(readManagedFile(fs,paths.manifest,{rootBoundary}));validateManifest(manifest);
 const policy=JSON.parse(readManagedFile(fs,paths.policy,{rootBoundary}));validateAuthorization(policy);
 let seedManifest=manifest;
 if(file===paths.romSeed){
  seedManifest=JSON.parse(readManagedFile(fs,paths.romManifest,{rootBoundary}));validateManifest(seedManifest);
  for(const key of ['version','hostname','origin_sni','origin_header_secret','username','password']){
   if(manifest[key]!==seedManifest[key])throw unavailable();
  }
 }
 return {seed:validateManagedSeed(raw,seedManifest),manifest,policy,...(file===paths.romSeed?{seedManifest}:{})};
}
export function luckyApi({fs=fsDefault,paths=managedPaths,rootBoundary='/',fetch=globalThis.fetch}={}){
 const token=readManagedFile(fs,paths.token,{rootBoundary,max:512}).trim();
 if(!secret(token))throw unavailable();
 return async(method,path,body)=>{
  try{
   const response=await fetch('http://127.0.0.1:16601'+path,{method,headers:{openToken:token,...(body?{'content-type':'application/json'}:{})},
    ...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(5000)});
   if(response.status!==200)throw unavailable();
   const text=await response.text();if(Buffer.byteLength(text)>1024*1024)throw unavailable();
   const value=JSON.parse(text);if(!object(value)||value.ret!==0)throw unavailable();return value;
  }catch{throw unavailable();}
 };
}

function validateAuthorization(policy){
 if(!object(policy))throw unavailable();
 if(policy.enabled===false)return policy;
 if(policy.enabled!==true||policy.hostname!==managedHostname||policy.source_policy!=='mtls'||
  typeof policy.client_ca_sha256!=='string'||!/^[a-f0-9]{64}$/.test(policy.client_ca_sha256)||
  !Array.isArray(policy.allowed_sources)||policy.allowed_sources.length)throw unavailable();
 return policy;
}
export function validateManagedKeys(raw){
 if(!object(raw)||Object.keys(raw).sort().join(',')!=='ddns_task_key,hostname,lucky_rule_key,origin_sni,ssl_task_key,version'||
  raw.version!==1||raw.hostname!==managedHostname||raw.origin_sni!==managedOrigin||
  !id(raw.lucky_rule_key)||!id(raw.ddns_task_key)||!id(raw.ssl_task_key))throw unavailable();
 return raw;
}
export class ManagedRegistry {
 constructor({fs=fsDefault,paths=managedPaths,rootBoundary='/'}={}){
  this.fs=fs;this.paths=paths;this.rootBoundary=rootBoundary;
 }
 read(){
  try{return validateManagedKeys(JSON.parse(readManagedFile(this.fs,this.paths.registry,{rootBoundary:this.rootBoundary,max:4096})));}
  catch(e){if(e.code==='ENOENT')return null;throw unavailable();}
 }
 acquire(){
  // Reuse the crash-safe filesystem bakery lease; it serializes our own
  // reconciler processes without pretending to lock administrator policy.
  return new OriginCertificateDeployer({fs:this.fs,paths:{lock:this.paths.lock},rootBoundary:this.rootBoundary}).acquire();
 }
 write(value,check){
  validateManagedKeys(value);this.read();
  const fs=this.fs,file=this.paths.registry,temp=file+'.'+randomBytes(12).toString('hex');
  let fd;
  try{
   fd=fs.openSync(temp,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
   fs.writeFileSync(fd,JSON.stringify(value,null,2)+'\n');fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
   check();fs.renameSync(temp,file);
   const dir=fs.openSync(dirname(file),fs.constants.O_RDONLY|fs.constants.O_DIRECTORY);
   try{fs.fsyncSync(dir);}finally{fs.closeSync(dir);}
  }finally{if(fd!==undefined)fs.closeSync(fd);try{fs.unlinkSync(temp);}catch(e){if(e.code!=='ENOENT')throw unavailable();}}
 }
}
function entries(raw,field){
 if(!object(raw)||raw.ret!==0||(raw[field]!==null&&!Array.isArray(raw[field])))throw unavailable();
 return raw[field]??[];
}
const definitions=[
 {kind:'rule',route:'/api/webservice/rules',list:'/api/webservice/rules',field:'ruleList',keyField:'RuleKey',nameField:'RuleName'},
 {kind:'ddns',route:'/api/ddns',list:'/api/ddnstasklist',field:'data',keyField:'TaskKey',nameField:'TaskName'},
 {kind:'ssl',route:'/api/ssl',list:'/api/ssl',field:'list',keyField:'Key',nameField:'Remark'}
];
function named(list,entry,manifest,seed){
 const matches=list.filter(row=>object(row)&&row[entry.nameField]===managedNames[entry.kind]);
 if(matches.length>1)throw unavailable();
 const reference=entry.kind==='rule'?manifest.lucky_rule_key:entry.kind==='ddns'?manifest.ddns_task_key:manifest.ssl_task_key;
 // A reference ID renamed to a different scope is not an invitation to
 // overwrite it or create a replacement alongside it.
 if(list.some(row=>object(row)&&[reference,seed[entry.keyField]].includes(row[entry.keyField])&&
  row[entry.nameField]!==managedNames[entry.kind]))throw unavailable();
 return matches[0]??null;
}
function matchingCredentials(live,seed,kind){
 const liveId=kind==='ddns'?live.DNS.ID:live.ExtParams.acmeDNSID;
 const seedId=kind==='ddns'?seed.DNS.ID:seed.ExtParams.acmeDNSID;
 if(liveId!==seedId)throw unavailable();
}
function stillSame(load,initial){
 const current=load();if(!current||current.policy?.enabled!==true||!equal(current,initial))throw unavailable();
}
function disabledEntries(values,seed){
 return Object.keys(values).filter(kind=>values[kind]?.Enable===false||
  (kind==='rule'&&values.rule?.ProxyList.some(child=>child.Enable===false))||seed[kind].Enable===false);
}
function checkScope(kind,value,seed){
 if(kind==='rule')validRule(value);
 else if(kind==='ddns'){validDns(value);matchingCredentials(value,seed,'ddns');}
 else{validSsl(value);matchingCredentials(value,seed,'ssl');}
}
async function details(api,entry,summary,seed){
 if(!summary)return null;
 const key=summary[entry.keyField];if(!id(key))throw unavailable();
 let value=summary;
 if(entry.kind!=='rule'){
  const response=await api('GET',entry.kind==='ddns'?'/api/ddns/task/'+encodeURIComponent(key):'/api/ssl/'+encodeURIComponent(key));
  value=entry.kind==='ddns'?response?.task:response?.info;
  if(response?.ret!==0||value?.[entry.keyField]!==key||value?.[entry.nameField]!==managedNames[entry.kind])throw unavailable();
 }
 checkScope(entry.kind,value,seed);return value;
}
function conflicting(rows,owned,entry){
 return rows.some(row=>row!==owned&&object(row)&&(
  entry.kind==='rule'?row.ListenPort===16801&&['127.0.0.1','0.0.0.0',''].includes(row.ListenIP):
  entry.kind==='ddns'?row.Records?.some(record=>record?.SyncRecordData?.fullDomainName===managedOrigin):
  row.ExtParams?.acmeDomains?.includes(managedOrigin)));
}
async function currentEntries(api,initial){
 const lists=await Promise.all(definitions.map(entry=>api('GET',entry.list)));
 const selected=definitions.map((entry,index)=>{
  const rows=entries(lists[index],entry.field),selected=named(rows,entry,initial.manifest,initial.seed[entry.kind]);
  if(conflicting(rows,selected,entry))throw unavailable();return selected;
 });
 const full=await Promise.all(definitions.map((entry,index)=>details(api,entry,selected[index],initial.seed[entry.kind])));
 return Object.fromEntries(definitions.map((entry,index)=>[entry.kind,full[index]]));
}
async function ensureSuffix(api,initial,load){
 // Native Lucky has no compare/exchange for this setting. Re-read just before
 // a merged append and verify afterward; all unrelated fields are preserved.
 const read=()=>api('GET','/api/ddns/configure');
 let response=await read();if(response?.ret!==0||!object(response.ddnsconfigure))throw unavailable();
 let config=response.ddnsconfigure;
 if(config.Enable===false)return false;
 if(typeof config.CustomDomainSuffix!=='string')throw unavailable();
 if(config.CustomDomainSuffix.split(/[,\s]+/).includes(initial.seed.domain_suffix))return true;
 stillSame(load,initial);response=await read();config=response.ddnsconfigure;
 if(response?.ret!==0||!object(config)||typeof config.CustomDomainSuffix!=='string')throw unavailable();
 if(config.Enable===false)return false;
 if(!config.CustomDomainSuffix.split(/[,\s]+/).includes(initial.seed.domain_suffix)){
  const next={...config,CustomDomainSuffix:config.CustomDomainSuffix+(config.CustomDomainSuffix&&!config.CustomDomainSuffix.endsWith('\n')?'\n':'')+initial.seed.domain_suffix+'\n'};
  stillSame(load,initial);
  const result=await api('PUT','/api/ddns/configure',next);if(result?.ret!==0)throw unavailable();
 }
 const after=await read();
 if(after?.ret!==0||typeof after.ddnsconfigure?.CustomDomainSuffix!=='string'||
  !after.ddnsconfigure.CustomDomainSuffix.split(/[,\s]+/).includes(initial.seed.domain_suffix))throw unavailable();
 return after.ddnsconfigure.Enable!==false;
}
function createPayload(entry,initial){
 const value=clone(initial.seed[entry.kind]);value[entry.keyField]='';
 if(entry.kind==='rule'){
  // Native POST allocates parent/child IDs. Credentials for a newly created
  // entry come from the current administrator manifest, never stale ROM text.
  value.DefaultProxy.Key='';value.DefaultProxy.GroupKey='';
  for(const child of value.ProxyList){child.Key='';child.GroupKey='';child.BasicAuthUserList=initial.manifest.username+':'+initial.manifest.password;}
 }else if(entry.kind==='ssl'){
  // A missing native ACME job must issue its own fresh certificate rather
  // than treating an old firmware's cached certificate/key as current.
  value.CertBase64='';value.KeyBase64='';value.IssuerCertificate='';value.AcmeErrorMsg='';
 }
 return value;
}
export async function reconcileLuckyManaged({load=loadManagedSeed,gate=restoreTerminal,api,registry}={}){
 let release,ownedLock,activeAdded=false;
 try{
  if(!gate())throw unavailable();
  const initial=load();if(initial===null)return {ready:false,skipped:true,created:[],disabled:[]};
  const {seed,manifest,policy}=initial;validateManagedSeed(seed,initial.seedManifest??manifest);validateManifest(manifest);validateAuthorization(policy);
  if(policy.enabled===false)return {ready:false,skipped:false,created:[],disabled:['policy']};
  registry??=new ManagedRegistry();ownedLock=registry.paths?.lock??registry;
  if(active.has(ownedLock))throw unavailable();active.add(ownedLock);activeAdded=true;
  release=registry.acquire();registry.read();api??=luckyApi();
  let present=await currentEntries(api,initial),disabled=disabledEntries(present,seed);
  if(disabled.length)return {ready:false,skipped:false,created:[],disabled};
  if(!await ensureSuffix(api,initial,load))return {ready:false,skipped:false,created:[],disabled:['ddns-global']};
  const created=[];
  for(const entry of definitions){
   if(present[entry.kind])continue;
   stillSame(load,initial);
   const rows=entries(await api('GET',entry.list),entry.field);
   const appeared=named(rows,entry,manifest,seed[entry.kind]);
   if(conflicting(rows,appeared,entry))throw unavailable();
   if(appeared){
    const current=await details(api,entry,appeared,seed[entry.kind]);present[entry.kind]=current;
    disabled=disabledEntries(present,seed);if(disabled.length)return {ready:false,skipped:false,created,disabled};continue;
   }
   const result=await api('POST',entry.route,createPayload(entry,initial));if(result?.ret!==0)throw unavailable();
   const readback=entries(await api('GET',entry.list),entry.field),stored=named(readback,entry,manifest,seed[entry.kind]);
   if(!stored||conflicting(readback,stored,entry))throw unavailable();
   const returned=result[entry.keyField]??result.key??result.rule?.RuleKey??result.task?.TaskKey??result.info?.Key;
   if(returned!==undefined&&returned!==stored[entry.keyField])throw unavailable();
   present[entry.kind]=await details(api,entry,stored,seed[entry.kind]);
   disabled=disabledEntries(present,seed);if(disabled.length)return {ready:false,skipped:false,created,disabled};
   created.push(entry.kind);
  }
  // Recovery needs no rollback of native user configuration. After a crash,
  // find the exact reserved names/scopes again and rebuild this owned map.
  present=await currentEntries(api,initial);
  if(Object.values(present).some(value=>!value))throw unavailable();
  disabled=disabledEntries(present,seed);if(disabled.length)return {ready:false,skipped:false,created,disabled};
  const keys={version:1,hostname:managedHostname,origin_sni:managedOrigin,lucky_rule_key:present.rule.RuleKey,
   ddns_task_key:present.ddns.TaskKey,ssl_task_key:present.ssl.Key};
  stillSame(load,initial);registry.write(keys,()=>stillSame(load,initial));
  return {ready:true,skipped:false,created,disabled:[],keys};
 }catch{throw unavailable();}
 finally{try{release?.();}finally{if(activeAdded)active.delete(ownedLock);}}
}
export async function managedMain({reconcile=reconcileLuckyManaged,stderr=text=>process.stderr.write(text),allowArgs=false}={}){
 try{
  if(!allowArgs&&process.argv.length>2)throw unavailable();
  const result=await reconcile();if(result.skipped||result.ready)return 0;throw unavailable();
 }catch{stderr(failure+'\n');return 1;}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href)process.exitCode=await managedMain();
