// One optional, approved CLIProxyAPI service. This is not a general LAN proxy.
import fsDefault from 'node:fs';
import {dirname} from 'node:path';
import {randomBytes} from 'node:crypto';

export const apiHostname='ai.lucky.jmsu.top';
export const apiRuleName='managed-cpe5g-ai-api-backend';
export const apiPaths=Object.freeze({config:'/etc/cpe5g-lucky/api-service.json',romConfig:'/rom/etc/cpe5g-lucky/api-service.json',keys:'/etc/cpe5g-lucky/api-native-keys.json',lock:'/etc/cpe5g-lucky/.api-native-lock'});
export const apiRequests=Object.freeze([
 Object.freeze({method:'GET',path:'/v1/models'}),
 Object.freeze({method:'POST',path:'/v1/chat/completions'}),
 Object.freeze({method:'POST',path:'/v1/responses'})
]);
export function defaultApiService(){return {version:1,enabled:false,publicHost:apiHostname,
 upstream:'http://127.0.0.1:8317',listen:'127.0.0.1:16802',authentication:'upstream-bearer',
 originSecretRef:'public-management.json#origin_header_secret',allowedRequests:apiRequests.map(x=>({...x})),
 nativeRuleKey:'cpe5g-api-public',nativeChildKey:'cpe5g-api-public-child'};}
const unavailable=()=>new Error('CPE API service unavailable');
const object=x=>x!==null&&typeof x==='object'&&!Array.isArray(x);
const id=x=>typeof x==='string'&&/^[A-Za-z0-9_-]{1,128}$/.test(x);
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const clone=x=>JSON.parse(JSON.stringify(x));
export function validateApiService(raw){
 const expected=defaultApiService();
 if(!object(raw)||Object.keys(raw).sort().join(',')!==Object.keys(expected).sort().join(',')||typeof raw.enabled!=='boolean')throw unavailable();
 for(const key of Object.keys(expected).filter(key=>!['enabled','allowedRequests'].includes(key)))if(!same(raw[key],expected[key]))throw unavailable();
 if(!Array.isArray(raw.allowedRequests)||raw.allowedRequests.length!==apiRequests.length||raw.allowedRequests.some(pair=>
  !object(pair)||Object.keys(pair).sort().join(',')!=='method,path'||!apiRequestAllowed(pair.method,pair.path))||
  new Set(raw.allowedRequests.map(pair=>pair.method+' '+pair.path)).size!==apiRequests.length)throw unavailable();
 return clone(raw);
}
// Walk parents as well as opening the leaf with O_NOFOLLOW. Exactly 0600,
// root-owned regular files are accepted; FIFO/symlink/unsafe parents fail shut.
export function readApiFile(fs,file){
 let at=dirname(file);
 while(true){
  const s=fs.lstatSync(at);
  if(!s.isDirectory()||s.isSymbolicLink()||s.uid!==0||(s.mode&0o022))throw unavailable();
  if(at==='/')break;at=dirname(at);
 }
 const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK);
 try{
  const s=fs.fstatSync(fd);
  if(!s.isFile()||s.uid!==0||(s.mode&0o777)!==0o600||s.size<1||s.size>16384)throw unavailable();
  const text=fs.readFileSync(fd,'utf8');if(Buffer.byteLength(text)!==s.size)throw unavailable();return text;
 }finally{fs.closeSync(fd);}
}
export function loadApiService({fs=fsDefault,paths=apiPaths}={}){
 try{return validateApiService(JSON.parse(readApiFile(fs,paths.config)));}catch{return null;}
}
// This optional file has its own narrow restore. Preserve every existing leaf,
// including an administrator's disabled/invalid file. Hard-link publication is
// no-clobber even if another process creates the destination during restoration.
export function restoreApiService({fs=fsDefault,paths=apiPaths}={}){
 let temp,fd;
 try{
  try{fs.lstatSync(paths.config);return loadApiService({fs,paths});}catch(e){if(e.code!=='ENOENT')return null;}
  const text=readApiFile(fs,paths.romConfig),service=validateApiService(JSON.parse(text));
  let at=dirname(paths.config);
  while(true){
   const s=fs.lstatSync(at);if(!s.isDirectory()||s.isSymbolicLink()||s.uid!==0||(s.mode&0o022))throw unavailable();
   if(at==='/')break;at=dirname(at);
  }
  temp=paths.config+'.restore-'+randomBytes(12).toString('hex');
  fd=fs.openSync(temp,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
  fs.writeFileSync(fd,JSON.stringify(service,null,2)+'\n');fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
  // Re-check through the production reader before touching the destination.
  validateApiService(JSON.parse(readApiFile(fs,temp)));
  try{fs.linkSync(temp,paths.config);}catch(e){if(e.code==='EEXIST')return loadApiService({fs,paths});throw e;}
  const directory=fs.openSync(dirname(paths.config),fs.constants.O_RDONLY|fs.constants.O_DIRECTORY);
  try{fs.fsyncSync(directory);}finally{fs.closeSync(directory);}
  return loadApiService({fs,paths});
 }catch{return null;}
 finally{if(fd!==undefined)try{fs.closeSync(fd);}catch{}if(temp)try{fs.unlinkSync(temp);}catch{}}
}
export function validateApiKeys(raw){
 if(!object(raw)||Object.keys(raw).sort().join(',')!=='enabled,hostname,lucky_child_key,lucky_rule_key,version'||
  raw.version!==1||raw.hostname!==apiHostname||typeof raw.enabled!=='boolean'||!id(raw.lucky_rule_key)||!id(raw.lucky_child_key)||
  raw.lucky_rule_key===raw.lucky_child_key)throw unavailable();
 return raw;
}
export function loadApiKeys({fs=fsDefault,paths=apiPaths}={}){
 try{return validateApiKeys(JSON.parse(readApiFile(fs,paths.keys)));}catch{return null;}
}
export function validateApiRule(rule,service){
 validateApiService(service);
 if(!object(rule)||!id(rule.RuleKey)||rule.RuleName!==apiRuleName||typeof rule.Enable!=='boolean'||
  rule.Network!=='tcp4'||rule.ListenIP!=='127.0.0.1'||rule.ListenPort!==16802||rule.EnableTLS!==false||rule.Http3!==false||
  rule.AutoOptionsFirewall===true||!object(rule.DefaultProxy)||rule.DefaultProxy.WebServiceType!=='close'||
  (rule.DefaultProxy.Locations?.length??0)!==0||!Array.isArray(rule.ProxyList)||rule.ProxyList.length!==1)throw unavailable();
 const child=rule.ProxyList[0];
 if(!object(child)||!id(child.Key)||typeof child.Enable!=='boolean'||child.WebServiceType!=='reverseproxy'||
  !same(child.Domains,[apiHostname])||!same(child.Locations,[service.upstream])||child.EnableBasicAuth!==false||
  (child.WebAuth??false)!==false||child.BasicAuthUserList!==''||child.UseRuleGlobalAuthSettings!==false||
  child.CacheEnabled!==false||!object(child.OtherParams)||child.OtherParams.WebAuth!==false||
  child.OtherParams.BasicAuthRegConf!==''||child.OtherParams.AutoOptionsFirewall!==false||
  (child.BasicAuthRegConf!==undefined&&child.BasicAuthRegConf!=='')||child.NginxConf||child.ProxyType||child.ProxyAddr||
  child.OtherParams.HttpClientProxyType||child.OtherParams.HttpClientProxyAddr)throw unavailable();
 return rule;
}
export function apiRuleFromTemplate(template,service){
 validateApiService(service);
 const rule=clone(template),child=rule.ProxyList?.[0];if(!child||!rule.DefaultProxy)throw unavailable();
 Object.assign(rule,{RuleKey:service.nativeRuleKey,RuleName:apiRuleName,Enable:true,ListenIP:'127.0.0.1',ListenPort:16802,AutoOptionsFirewall:false});
 Object.assign(rule.DefaultProxy,{EnableBasicAuth:false,WebAuth:false,BasicAuthUserList:'',UseRuleGlobalAuthSettings:false});
 if(rule.DefaultProxy.OtherParams)Object.assign(rule.DefaultProxy.OtherParams,{WebAuth:false,BasicAuthRegConf:'',AutoOptionsFirewall:false});
 Object.assign(child,{Key:service.nativeChildKey,Enable:true,Domains:[apiHostname],Locations:[service.upstream],
  EnableBasicAuth:false,WebAuth:false,BasicAuthUserList:'',BasicAuthRegConf:'',UseRuleGlobalAuthSettings:false,CacheEnabled:false});
 Object.assign(child.OtherParams,{WebAuth:false,BasicAuthRegConf:'',AutoOptionsFirewall:false});
 return validateApiRule(rule,service);
}
export function apiRequestAllowed(method,target){return apiRequests.some(x=>x.method===method&&x.path===target);}
// No credentials are needed for health: CPA must reject absent/invalid Bearer.
// Scope is checked from Lucky's live native config, so an administrator disable
// cannot be silently re-enabled by a healthy unrelated loopback process.
export async function apiBackendReady(service,{api,keys,fetch=globalThis.fetch,signal}={}){
 try{
  validateApiService(service);validateApiKeys(keys);if(!service.enabled||!keys.enabled)return false;
  const result=await api('GET','/api/webservice/rules');
  if(result?.ret!==0||!Array.isArray(result.ruleList))return false;
  const rows=result.ruleList.filter(row=>row?.RuleName===apiRuleName);
  if(rows.length!==1)return false;
  const rule=validateApiRule(rows[0],service);
  if(!rule.Enable||!rule.ProxyList[0].Enable||rule.RuleKey!==keys.lucky_rule_key||rule.ProxyList[0].Key!==keys.lucky_child_key)return false;
  for(const headers of [{},{Authorization:'Bearer CPE_API_HEALTH_INVALID'}]){
   if(signal?.aborted)return false;
   const response=await fetch('http://127.0.0.1:16802/v1/models',{headers:{Host:apiHostname,...headers},redirect:'error',
    signal:signal?AbortSignal.any([signal,AbortSignal.timeout(3000)]):AbortSignal.timeout(3000)});
   await response.body?.cancel();if(response.status!==401)return false;
  }
  return true;
 }catch{return false;}
}
