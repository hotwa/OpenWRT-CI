// Optional CPE-only origin. The controller owns routing/quota; this process
// owns only its HAProxy child and a short-lived, behavior-proved ready record.
import fsDefault from 'node:fs';
import {createHash,createPrivateKey,createPublicKey,randomBytes,X509Certificate} from 'node:crypto';
import {execFileSync,spawn as spawnDefault} from 'node:child_process';
import tls from 'node:tls';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {selectOriginIpv6} from './select-origin-ipv6.mjs';
import {certificatePinPath,restoreJournal,guardVersion,publicConfig} from './public-access.mjs';
import {apiPaths,apiHostname,loadApiService,loadApiKeys,validateApiService,apiBackendReady} from './api-service-registry.mjs';

export const hostname='cpe.lucky.jmsu.top';
export const originSni='cpe-origin.jmsu.top';
export const originPort=18443;
export const paths=Object.freeze({
 policy:'/etc/cpe5g/public-origin.json',manifest:'/etc/cpe5g-lucky/public-management.json',
 token:'/etc/lucky/cert-sync/lucky.token',
 chain:'/etc/lucky/cert-sync/cpe5g-origin/current/fullchain.pem',
 key:'/etc/lucky/cert-sync/cpe5g-origin/current/privkey.pem',
 certificatePin:certificatePinPath,
 deployJournal:'/etc/lucky/cert-sync/cpe5g-origin/.deploy-journal',
 restoreJournal,
 clientCa:'/etc/cpe5g-lucky/tls/client-ca.pem',
 healthCert:'/etc/cpe5g-lucky/tls/health-client.crt',healthKey:'/etc/cpe5g-lucky/tls/health-client.key',
 runtime:'/var/run/cpe5g-lucky',config:'/var/run/cpe5g-lucky/haproxy.cfg',
 serverPem:'/var/run/cpe5g-lucky/server.pem',runtimeCa:'/var/run/cpe5g-lucky/client-ca.pem',
 httpSocket:'/var/run/cpe5g-lucky/origin-http.sock',
 ready:'/var/run/cpe5g-lucky/public-ready.json',apiReady:'/var/run/cpe5g-lucky/api-ready.json'
});
const haproxy='/usr/sbin/haproxy';
const lifetime=72*60*60*1000;
const unavailable=()=>new Error('CPE public origin unavailable');
const hash=value=>createHash('sha256').update(value).digest('hex');
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const hex=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value);
const keyId=value=>typeof value==='string'&&value.length>0&&value.length<=256&&!/[\x00-\x20\x7f]/.test(value);

export function readRootFile(fs,file,{secret=false,max=131072}={}){
 const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK);
 try{
  const s=fs.fstatSync(fd);
  if(!s.isFile()||s.uid!==0||(s.mode&(secret?0o077:0o022))||s.size<1||s.size>max)throw unavailable();
  const text=fs.readFileSync(fd,'utf8');
  if(Buffer.byteLength(text)>max)throw unavailable();
  return text;
 }finally{fs.closeSync(fd);}
}
function json(fs,file,secret=false){return JSON.parse(readRootFile(fs,file,{secret,max:65536}));}
export function validatePolicy(raw,pin){
 if(!object(raw))throw unavailable();
 if(raw.enabled===false)return null;
 if(raw.enabled!==true||raw.hostname!==hostname||raw.source_policy!=='mtls'||
  !hex(raw.client_ca_sha256)||!Array.isArray(raw.allowed_sources)||raw.allowed_sources.length)throw unavailable();
 if(pin===undefined){if(!hex(raw.server_cert_sha256))throw unavailable();}
 else if(!object(pin)||pin.version!==1||pin.hostname!==hostname||pin.origin_sni!==originSni||!hex(pin.server_cert_sha256))throw unavailable();
 const effective=publicConfig(raw,pin);
 if(!effective)throw unavailable();
 return {...raw,client_ca_sha256:effective.client_ca_sha256,server_cert_sha256:effective.server_cert_sha256};
}
export function validateManifest(raw){
 if(!object(raw)||raw.version!==1||raw.hostname!==hostname||raw.origin_sni!==originSni||
  !keyId(raw.lucky_rule_key)||!keyId(raw.ddns_task_key)||!hex(raw.origin_header_secret)||
  raw.username!=='cpe-temp'||typeof raw.password!=='string'||!/^[\x21-\x7e]{24,256}$/.test(raw.password))throw unavailable();
 return raw;
}
function certificates(pem){
 const blocks=pem.match(/-----BEGIN CERTIFICATE-----\r?\n[\s\S]+?-----END CERTIFICATE-----/g);
 if(!blocks?.length||blocks.length>8||pem.replace(/-----BEGIN CERTIFICATE-----\r?\n[\s\S]+?-----END CERTIFICATE-----/g,'').trim())throw unavailable();
 return blocks.map(block=>new X509Certificate(block));
}
function validDates(cert,now){
 const begin=Date.parse(cert.validFrom),end=Date.parse(cert.validTo);
 if(!Number.isSafeInteger(now)||now<0||!Number.isFinite(begin)||!Number.isFinite(end)||begin>now||end-now<=lifetime)throw unavailable();
}
function keyMatches(cert,pem){
 const key=createPrivateKey(pem);
 if(!cert.publicKey.export({type:'spki',format:'der'}).equals(createPublicKey(key).export({type:'spki',format:'der'})))throw unavailable();
}
function noDeployment(fs){
 for(const file of [paths.deployJournal,paths.restoreJournal]){
  try{fs.lstatSync(file);}catch(e){if(e.code==='ENOENT')continue;throw unavailable();}
  throw unavailable();
 }
}
export function validateMaterials({chain,key,clientCa,healthCert,healthKey},policy,now){
 const server=certificates(chain),ca=certificates(clientCa),health=certificates(healthCert);
 if(ca.length!==1||health.length!==1||server[0].ca||!ca[0].ca||health[0].ca||
  server[0].checkHost(originSni,{subject:'never',wildcards:false})!==originSni)throw unavailable();
 for(const cert of [...server,...ca,...health])validDates(cert,now);
 keyMatches(server[0],key);keyMatches(health[0],healthKey);
 for(let i=0;i<server.length-1;i++)if(!server[i+1].ca||!server[i].checkIssued(server[i+1])||!server[i].verify(server[i+1].publicKey))throw unavailable();
 if(!health[0].checkIssued(ca[0])||!health[0].verify(ca[0].publicKey))throw unavailable();
 const client_ca_sha256=hash(ca[0].raw),server_cert_sha256=hash(server[0].raw);
 if(client_ca_sha256!==policy.client_ca_sha256||server_cert_sha256!==policy.server_cert_sha256)throw unavailable();
 return {client_ca_sha256,server_cert_sha256};
}
export function loadOrigin({fs=fsDefault,now=Date.now}={}){
 let rawPolicy;
 try{rawPolicy=json(fs,paths.policy);}catch(e){if(e.code==='ENOENT')return null;throw unavailable();}
 if(rawPolicy?.enabled===false)return validatePolicy(rawPolicy);
 try{
  noDeployment(fs);
  const pinText=readRootFile(fs,paths.certificatePin,{max:65536});
  const pin=JSON.parse(pinText),policy=validatePolicy(rawPolicy,pin);
  const manifest=validateManifest(json(fs,paths.manifest,true));
  const material={chain:readRootFile(fs,paths.chain),key:readRootFile(fs,paths.key,{secret:true}),
   clientCa:readRootFile(fs,paths.clientCa),healthCert:readRootFile(fs,paths.healthCert),healthKey:readRootFile(fs,paths.healthKey,{secret:true})};
  const pins=validateMaterials(material,policy,now());
  return {manifest,material,pins,digest:hash(JSON.stringify({policy,pinText,manifest,material}))};
 }catch{throw unavailable();}
}
export function haproxyConfig(manifest,api=null){
 validateManifest(manifest);
 if(api){validateApiService(api);if(!api.enabled)api=null;}
 // All interpolated values are fixed paths or a validated 64-character hex
 // value. Credentials never enter the HAProxy configuration or process args.
 return `global
  maxconn 128
  hard-stop-after 2s
  noreuseport

defaults
  mode http
  no log
  timeout connect 3s
  timeout client ${api?'300s':'30s'}
  timeout server 30s
  timeout http-request 5s
  option httpclose

frontend cpe_public_tls
  mode tcp
  bind :::18443 v6only ssl crt ${paths.serverPem} ca-file ${paths.runtimeCa} verify required ssl-min-ver TLSv1.2
  tcp-request inspect-delay 5s
  # The H1 parser coalesces identical Host fields before HTTP ACLs. Inspect
  # complete raw headers first; the expression never reaches a request body.
  tcp-request content set-var(sess.raw_headers) req.payload(0,0) if { req.proto_http }
  acl duplicate_raw_host var(sess.raw_headers),lower -m reg '^[^\\r\\n]*\\r\\n([^\\r\\n]+\\r\\n)*host:[^\\r\\n]*\\r\\n([^\\r\\n]+\\r\\n)*host:'
  acl origin_sni ssl_fc_sni -m str ${originSni}
  tcp-request content reject unless origin_sni
  tcp-request content reject if duplicate_raw_host
  tcp-request content unset-var(sess.raw_headers) if { req.proto_http }
  tcp-request content accept if { req.proto_http }
  tcp-request content reject
  default_backend cpe_http_transport

backend cpe_http_transport
  mode tcp
  timeout server ${api?'300s':'30s'}
  server local_http ${paths.httpSocket}

frontend cpe_public_http
  # Only the owned TLS transport can reach this root-only UNIX listener.
  bind ${paths.httpSocket} mode 600
  acl one_host req.fhdr_cnt(Host) eq 1
  acl origin_host req.fhdr(Host),lower -m str ${hostname}
${api?`  acl api_host req.fhdr(Host),lower -m str ${apiHostname}
  acl api_get method -m str GET
  acl api_post method -m str POST
  acl api_models url -m str /v1/models
  acl api_posts url -m str /v1/chat/completions /v1/responses
`:''}  acl approved_host req.fhdr(Host),lower -m str ${hostname}${api?' '+apiHostname:''}
  acl one_secret req.fhdr_cnt(X-CPE-Origin) eq 1
  acl origin_secret req.fhdr(X-CPE-Origin) -m str ${manifest.origin_header_secret}
  http-request deny deny_status 403 unless one_host approved_host one_secret origin_secret
${api?`  # Exact raw request targets reject percent escapes, queries, absolute form,
  # slash/dot normalization and case variations before either proxy sees them.
  http-request deny deny_status 403 if api_host !api_get !api_post
  http-request deny deny_status 403 if api_host api_get !api_models
  http-request deny deny_status 403 if api_host api_post !api_posts
  http-request deny deny_status 403 if api_host { req.fhdr_cnt(Authorization) gt 1 }
`:''}  http-request del-header X-CPE-Origin
  http-request set-header X-Forwarded-Proto https
${api?'  use_backend cpe_lucky_api if api_host\n':''}  default_backend cpe_lucky_private

backend cpe_lucky_private
  # Match each complete Set-Cookie independently; other cookies and existing
  # attributes remain exact, including stricter SameSite policies.
  http-response replace-header Set-Cookie '^(?!.*;[[:blank:]]*(?i:secure)[[:blank:]]*(?:=|;|$))(LuckyWebAuthorization_[^=;[:space:]]+=.*)$' '\\1; Secure'
  http-response replace-header Set-Cookie '^(?!.*;[[:blank:]]*(?i:samesite)[[:blank:]]*(?:=|;|$))(LuckyWebAuthorization_[^=;[:space:]]+=.*)$' '\\1; SameSite=Lax'
  server lucky 127.0.0.1:16801
${api?`
backend cpe_lucky_api
  # 300s is an idle timeout, not a promise about ESA's total stream duration.
  timeout server 300s
  option http-no-delay
  http-response set-header Cache-Control "no-store, no-transform"
  server lucky_api 127.0.0.1:16802
`:''}
`;
}
function secureRuntime(fs){
 fs.mkdirSync(paths.runtime,{recursive:true,mode:0o700});
 const s=fs.lstatSync(paths.runtime);
 if(!s.isDirectory()||s.isSymbolicLink()||s.uid!==0||(s.mode&0o022))throw unavailable();
 fs.chmodSync(paths.runtime,0o700);
}
function atomic(fs,file,text){
 const temp=file+'.'+process.pid+'.'+randomBytes(8).toString('hex');
 let fd;
 try{
  fd=fs.openSync(temp,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
  fs.writeFileSync(fd,text);fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
  fs.renameSync(temp,file);
 }finally{
  if(fd!==undefined)fs.closeSync(fd);
  try{fs.unlinkSync(temp);}catch(e){if(e.code!=='ENOENT')throw unavailable();}
 }
}
function remove(fs,file){try{fs.unlinkSync(file);}catch(e){if(e.code!=='ENOENT')throw unavailable();}}
const abortError=()=>Object.assign(unavailable(),{code:'ABORT_ERR'});
function sleep(ms,signal){
 return new Promise((resolve,reject)=>{
  if(signal?.aborted)return reject(abortError());
  const cleanup=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);};
  const abort=()=>{cleanup();reject(abortError());};
  const timer=setTimeout(()=>{cleanup();resolve();},ms);
  signal?.addEventListener('abort',abort,{once:true});
 });
}
function parseHttp(bytes){
 const split=bytes.indexOf('\r\n\r\n');
 if(split<0||split>16384)throw unavailable();
 const header=bytes.subarray(0,split).toString('latin1');
 const match=header.match(/^HTTP\/1\.[01] (\d{3})(?: |\r\n)/);
 if(!match)throw unavailable();
 let body=bytes.subarray(split+4);
 if(/\r\ntransfer-encoding:\s*chunked\s*(?:\r\n|$)/i.test(header)){
  const chunks=[];let at=0;
  while(true){
   const end=body.indexOf('\r\n',at);if(end<0)throw unavailable();
   const lengthText=body.subarray(at,end).toString('ascii').split(';')[0];
   if(!/^[0-9a-f]+$/i.test(lengthText))throw unavailable();
   const n=parseInt(lengthText,16);at=end+2;
   if(!n)break;
   if(n>65536||at+n+2>body.length||body.subarray(at+n,at+n+2).toString()!=='\r\n')throw unavailable();
   chunks.push(body.subarray(at,at+n));at+=n+2;
  }
  body=Buffer.concat(chunks);
 }
 const length=header.match(/\r\ncontent-length:\s*(\d+)\s*(?:\r\n|$)/i);
 if(length&&Number(length[1])!==body.length)throw unavailable();
 return {status:Number(match[1]),body:body.toString('utf8')};
}
// Raw HTTP permits a real duplicate-header probe. TLS uses an independently
// pinned DER leaf and exact SAN; the public CA store is not needed for this
// local-only check. A TLS alert, never a timeout/403/reset, proves mandatory
// client authentication. No response headers or bodies are logged.
export function tlsRequest({material,pins,path='/',method='GET',headers=[],client=true,signal,timeout=3000}={}){
 return new Promise((resolve,reject)=>{
  if(signal?.aborted)return reject(abortError());
  let socket,done=false,total=0;const parts=[];
  const finish=(error,value)=>{
   if(done)return;done=true;clearTimeout(timer);signal?.removeEventListener('abort',abort);
   socket?.destroy();error?reject(error):resolve(value);
  };
  const abort=()=>finish(abortError());
  const timer=setTimeout(()=>finish(unavailable()),timeout);
  signal?.addEventListener('abort',abort,{once:true});
  try{
   socket=tls.connect({host:'::1',port:originPort,servername:originSni,rejectUnauthorized:false,
    minVersion:'TLSv1.2',...(client?{cert:material.healthCert,key:material.healthKey}:{})},()=>{
    const peer=socket.getPeerCertificate();
    if(!peer.raw||hash(peer.raw)!==pins.server_cert_sha256||tls.checkServerIdentity(originSni,peer))return finish(unavailable());
    const defaultHost=headers.some(([name])=>name.toLowerCase()==='host')?'':`Host: ${hostname}\r\n`;
    socket.write(`${method} ${path} HTTP/1.1\r\n${defaultHost}Connection: close\r\nAccept-Encoding: identity\r\n${headers.map(([name,value])=>`${name}: ${value}\r\n`).join('')}\r\n`);
   });
   socket.on('data',data=>{total+=data.length;if(total>81920)return finish(unavailable());parts.push(data);});
   socket.on('end',()=>{try{finish(null,parseHttp(Buffer.concat(parts)));}catch{finish(unavailable());}});
   socket.on('error',e=>{
    if(!client&&['ERR_SSL_TLSV13_ALERT_CERTIFICATE_REQUIRED','ERR_SSL_SSLV3_ALERT_HANDSHAKE_FAILURE',
     'ERR_SSL_PEER_DID_NOT_RETURN_A_CERTIFICATE','ERR_SSL_TLSV1_ALERT_CERTIFICATE_REQUIRED'].includes(e.code))return finish(null,{tlsDenied:true});
    finish(unavailable());
   });
   socket.on('close',()=>{if(!done)finish(unavailable());});
  }catch{finish(unavailable());}
 });
}
export async function probeOrigin(origin,{request=tlsRequest,signal}={}){
 const {manifest,material,pins}=origin;
 const basic='Basic '+Buffer.from(manifest.username+':'+manifest.password).toString('base64');
 const secret=['X-CPE-Origin',manifest.origin_header_secret],auth=['Authorization',basic];
 const call=(options,expected)=>request({material,pins,signal,...options}).then(result=>{
  if(expected==='tls'?result?.tlsDenied!==true:result?.status!==expected)throw unavailable();
  return result;
 });
 const [noClient,missing,wrong,duplicate,comma,wrongHost,root,api,staticAsset,badBasic,goodRoot,goodApi,udxLogin]=await Promise.all([
  call({client:false,headers:[secret,auth]},'tls'),call({headers:[auth]},403),
  call({headers:[['X-CPE-Origin',manifest.origin_header_secret==='0'.repeat(64)?'1'.repeat(64):'0'.repeat(64)],auth]},403),
  call({headers:[secret,secret,auth]},403),call({headers:[['X-CPE-Origin',manifest.origin_header_secret+','+manifest.origin_header_secret],auth]},403),
  call({headers:[secret,auth,['Host','unmatched.invalid']]},403),
  call({headers:[secret]},401),call({path:'/api/auth/status',headers:[secret]},401),call({path:'/static/cpe-origin-probe.js',headers:[secret]},401),
  call({headers:[secret,['Authorization','Basic '+Buffer.from('cpe-temp:invalid').toString('base64')]]},401),
  call({headers:[secret,auth]},200),call({path:'/api/auth/status',headers:[secret,auth]},200),
  call({path:'/api/netif/list',headers:[secret,auth]},401)
 ]);
 if(signal?.aborted||noClient?.tlsDenied!==true||[missing,wrong,duplicate,comma,wrongHost].some(r=>r?.status!==403)||
  [root,api,staticAsset,badBasic,udxLogin].some(r=>r?.status!==401)||goodRoot?.status!==200||!goodRoot.body?.trim()||goodApi?.status!==200)throw unavailable();
 let status;try{status=JSON.parse(goodApi.body);}catch{throw unavailable();}
 if(!object(status)||status.logged_in!==false||status.auth_required!==true)throw unavailable();
 return {mtls_verified:true,origin_header_verified:true};
}
export async function probeApiOrigin(origin,{request=tlsRequest,signal}={}){
 try{
  const headers=[['Host',apiHostname],['X-CPE-Origin',origin.manifest.origin_header_secret]];
  for(const [method,path,extra,status] of [
   ['GET','/v1/models',[],401],['GET','/v1/models',[['Authorization','Bearer CPE_API_HEALTH_INVALID']],401],
   ['GET','/management',[],403],['GET','/v1/responses',[],403],['POST','/v1/models',[],403],
   ['GET','/v1/%6dodels',[],403],['GET','/v1//models',[],403]
  ]){
   const result=await request({material:origin.material,pins:origin.pins,signal,method,path,headers:[...headers,...extra]});
   if(result?.status!==status)return false;
  }
  return !signal?.aborted;
 }catch{return false;}
}
export async function checkApiBackend(service,{fs=fsDefault,fetch=globalThis.fetch,signal}={}){
 try{
  const token=readRootFile(fs,paths.token,{secret:true,max:512}).trim();
  if(!keyId(token))return false;
  const api=async(method,path)=>{
   const response=await fetch('http://127.0.0.1:16601'+path,{method,headers:{openToken:token},signal:AbortSignal.timeout(3000)});
   if(response.status!==200)throw unavailable();
   const text=await response.text();if(Buffer.byteLength(text)>1024*1024)throw unavailable();return JSON.parse(text);
  };
  return await apiBackendReady(service,{api,keys:loadApiKeys({fs}),signal});
 }catch{return false;}
}

export function ownedListener(child,fs=fsDefault){
 try{
  if(!Number.isSafeInteger(child?.pid)||child.pid<1)return false;
  const base='/proc/'+child.pid;
  const table=fs.readFileSync(base+'/net/tcp6','utf8');
  if(table.length>1048576)return false;
  const listening=new Set(table.split('\n').slice(1).map(line=>line.trim().split(/\s+/))
   .filter(row=>row[1]==='00000000000000000000000000000000:480B'&&row[3]==='0A'&&/^\d+$/.test(row[9]||''))
   .map(row=>row[9]));
  if(!listening.size)return false;
  return fs.readdirSync(base+'/fd').some(fd=>{
   if(!/^\d+$/.test(fd))return false;
   try{return listening.has(fs.readlinkSync(base+'/fd/'+fd).match(/^socket:\[(\d+)\]$/)?.[1]);}catch{return false;}
  });
 }catch{return false;}
}
export function ownedGuard(run){
 try{return guardVersion(run('nft',['list','table','inet','cpe6_guard']),'usb0')===4;}catch{return false;}
}

export class LuckyOrigin {
 #child=null;#digest=null;#busy=null;#stopping=false;#probeAbort=null;#state=null;#stopPending=null;
 constructor({fs=fsDefault,now=Date.now,run=(bin,args)=>execFileSync(bin,args,{encoding:'utf8',timeout:3000,maxBuffer:65536,stdio:['ignore','pipe','pipe']}),
  spawn=spawnDefault,select=()=>selectOriginIpv6({fs,now,run}),probe=probeOrigin,probeApi=probeApiOrigin,
  apiCheck=(service,options)=>checkApiBackend(service,{fs,...options}),wait=sleep,
  ownsListener=child=>ownedListener(child,fs),log=text=>process.stderr.write(text+'\n')}={}){
  Object.assign(this,{fs,now,run,spawn,select,probe,probeApi,apiCheck,wait,ownsListener,log});
 }
 get child(){return this.#child?.process||null;}
 #message(state){if(state!==this.#state){this.#state=state;this.log(state==='ready'?'CPE public origin ready':'CPE public origin unavailable');}}
 #clear(){remove(this.fs,paths.ready);remove(this.fs,paths.apiReady);}
 async #stopChild(){
  if(this.#stopPending)return this.#stopPending;
  const active=this.#terminate();this.#stopPending=active;
  try{return await active;}finally{if(this.#stopPending===active)this.#stopPending=null;}
 }
 async #terminate(){
  const owned=this.#child;this.#digest=null;
  if(!owned||owned.dead){this.#child=null;return;}
  // Only ChildProcess objects returned by this instance's spawn are signaled.
  // Never read a PID file or signal a PID discovered in the system.
  owned.retiring=true;owned.process.kill('SIGTERM');
  const bounded=async ms=>{
   const abort=new AbortController();
   try{await Promise.race([owned.closed,this.wait(ms,abort.signal)]);}finally{abort.abort();}
  };
  await bounded(1500);
  if(!owned.dead){owned.process.kill('SIGKILL');await bounded(750);}
  if(!owned.dead)throw unavailable();
  if(this.#child===owned)this.#child=null;
 }
 #start(origin){
  const process=this.spawn(haproxy,['-db','-f',paths.config],{stdio:['ignore','ignore','ignore']});
  let resolveClosed;const owned={process,dead:false,closed:new Promise(resolve=>{resolveClosed=resolve;})};
  this.#child=owned;this.#digest=origin.digest;
  const dead=()=>{
   if(owned.dead)return;owned.dead=true;resolveClosed();
   if(this.#child===owned){if(!owned.retiring)this.#probeAbort?.abort();try{this.#clear();}catch{}this.#message('unavailable');}
  };
  process.once('exit',dead);process.once('error',dead);
 }
 async #ensure(origin){
  if(this.#child&&!this.#child.dead&&this.#digest===origin.digest)return;
  this.#clear();await this.#stopChild();if(this.#stopping)throw unavailable();
  secureRuntime(this.fs);
  atomic(this.fs,paths.serverPem,origin.material.chain.trim()+'\n'+origin.material.key.trim()+'\n');
  atomic(this.fs,paths.runtimeCa,origin.material.clientCa);
  atomic(this.fs,paths.config,haproxyConfig(origin.manifest,origin.api));
  this.run(haproxy,['-c','-f',paths.config]);
  if(this.#stopping||!ownedGuard(this.run))throw unavailable();
  this.#start(origin);
  for(let n=0;n<30&&!this.#stopping&&!this.#child.dead;n++){
   await this.wait(50);if(this.ownsListener(this.#child.process))break;
  }
 }
 async #tick(){
  if(this.#stopping)return false;
  try{
   let origin=loadOrigin({fs:this.fs,now:this.now});
   if(!origin){this.#clear();await this.#stopChild();this.#message('unavailable');return false;}
   const before=this.select();
   if(!ownedGuard(this.run))throw unavailable();
   const sourceDigest=origin.digest,service=loadApiService({fs:this.fs});
   let api=null;
   const abort=new AbortController();this.#probeAbort=abort;
   try{if(service?.enabled&&await this.apiCheck(service,{signal:abort.signal}))api=service;}catch{}
   const effective=api=>({...origin,api,digest:hash(JSON.stringify({sourceDigest,api}))});
   origin=effective(api);await this.#ensure(origin);
   if(api){
    let passed=false;try{passed=await this.probeApi(origin,{signal:abort.signal});}catch{}
    if(!passed||JSON.stringify(loadApiService({fs:this.fs}))!==JSON.stringify(service)){
     api=null;origin=effective(null);await this.#ensure(origin);
    }
   }
   let owned=this.#child;
   if(this.#stopping||!owned||owned.dead||!this.ownsListener(owned.process))throw unavailable();
   let verified=await this.probe(origin,{signal:abort.signal});
   if(api&&JSON.stringify(loadApiService({fs:this.fs}))!==JSON.stringify(service)){
    api=null;origin=effective(null);await this.#ensure(origin);owned=this.#child;
    verified=await this.probe(origin,{signal:abort.signal});
   }
   if(this.#stopping||abort.signal.aborted||owned!==this.#child||owned.dead||
    verified?.mtls_verified!==true||verified?.origin_header_verified!==true)throw unavailable();
   const after=loadOrigin({fs:this.fs,now:this.now}),address=this.select();
   if(!after||after.digest!==sourceDigest||before!==address||!this.ownsListener(owned.process)||!ownedGuard(this.run))throw unavailable();
   noDeployment(this.fs);
   this.#clear();
   atomic(this.fs,paths.ready,JSON.stringify({ready:true,hostname,source_policy:'mtls',port:originPort,address,
    updated:this.now(),...origin.pins,mtls_verified:true,origin_header_verified:true})+'\n');
   atomic(this.fs,paths.apiReady,JSON.stringify({version:1,api_route:true,approved_host:apiHostname,ready:!!api,
    updated:this.now(),shared_gate:'udx'})+'\n');
   noDeployment(this.fs);
   if(!ownedGuard(this.run))throw unavailable();
   this.#message('ready');return true;
  }catch{
   this.#probeAbort?.abort();try{this.#clear();}catch{}
   try{await this.#stopChild();}catch{}
   this.#message('unavailable');return false;
  }finally{this.#probeAbort=null;}
 }
 tick(){
  if(this.#busy)return this.#busy;
  const active=this.#tick();this.#busy=active;
  active.finally(()=>{if(this.#busy===active)this.#busy=null;});return active;
 }
 async stop(){
  this.#stopping=true;this.#probeAbort?.abort();
  try{this.#clear();}finally{await this.#stopChild();}
  if(this.#busy)await this.#busy;
  for(const file of [paths.config,paths.serverPem,paths.runtimeCa,paths.httpSocket])remove(this.fs,file);
 }
}
export async function originMain({signal,interval=5000,wait=sleep,...options}={}){
 const controller=new LuckyOrigin({...options,wait});
 const abort=()=>{void controller.stop().catch(()=>{});};
 signal?.addEventListener('abort',abort,{once:true});
 try{
  while(!signal?.aborted){await controller.tick();if(!signal?.aborted)await wait(interval,signal);}
 }catch{}finally{signal?.removeEventListener('abort',abort);await controller.stop();}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 const abort=new AbortController();
 process.once('SIGTERM',()=>abort.abort());process.once('SIGINT',()=>abort.abort());
 originMain({signal:abort.signal}).catch(()=>{process.stderr.write('CPE public origin unavailable\n');process.exitCode=1;});
}
