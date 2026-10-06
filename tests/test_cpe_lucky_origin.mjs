import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import {EventEmitter} from 'node:events';
import {createHash,X509Certificate} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
import {test,after} from 'node:test';
import {hostname,originSni,originPort,paths,readRootFile,validateManifest,validatePolicy,validateMaterials,
 loadOrigin,haproxyConfig,probeOrigin,tlsRequest,ownedListener,ownedGuard,LuckyOrigin,originMain} from '../Scripts/cpe5g-ipv6/lucky-origin.mjs';
import {nativeAddress} from '../Scripts/cpe5g-ipv6/model.mjs';
import {statusPath} from '../Scripts/cpe5g-ipv6/select-origin-ipv6.mjs';
import {guardDefinition} from '../Scripts/cpe5g-ipv6/public-access.mjs';
import {apiPaths,apiHostname,defaultApiService,validateApiService,restoreApiService} from '../Scripts/cpe5g-ipv6/api-service-registry.mjs';

const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-origin-cert-'));
after(()=>fs.rmSync(dir,{recursive:true,force:true}));
const openssl=args=>execFileSync('openssl',args,{cwd:dir,stdio:['ignore','ignore','ignore']});
openssl(['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-keyout','ca.key','-out','ca.pem','-days','14','-subj','/CN=CPE dedicated health CA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign']);
function signed(name,cn,extensions){
 openssl(['req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-keyout',name+'.key','-out',name+'.csr','-subj','/CN='+cn]);
 fs.writeFileSync(path.join(dir,name+'.ext'),'basicConstraints=critical,CA:FALSE\n'+extensions+'\n');
 openssl(['x509','-req','-in',name+'.csr','-CA','ca.pem','-CAkey','ca.key','-CAcreateserial','-days','14','-out',name+'.pem','-extfile',name+'.ext']);
}
signed('server',originSni,'subjectAltName=DNS:'+originSni+'\nextendedKeyUsage=serverAuth');
signed('health','CPE local origin health','extendedKeyUsage=clientAuth');
signed('wrong','unmatched.invalid','subjectAltName=DNS:unmatched.invalid\nextendedKeyUsage=serverAuth');
signed('renewed',originSni,'subjectAltName=DNS:'+originSni+'\nextendedKeyUsage=serverAuth');
const certFile=name=>fs.readFileSync(path.join(dir,name),'utf8');
const material={chain:certFile('server.pem')+certFile('ca.pem'),key:certFile('server.key'),clientCa:certFile('ca.pem'),healthCert:certFile('health.pem'),healthKey:certFile('health.key')};
const fingerprint=pem=>createHash('sha256').update(new X509Certificate(pem).raw).digest('hex');
const pins={client_ca_sha256:fingerprint(material.clientCa),server_cert_sha256:fingerprint(material.chain)};
const manifest=()=>({version:1,hostname,origin_sni:originSni,lucky_rule_key:'managed-cpe-public',ddns_task_key:'managed-cpe-ddns',origin_header_secret:'a'.repeat(64),username:'cpe-temp',password:'TestFixtureOnly_24Character-Password!'});
const policy=()=>({enabled:true,hostname,source_policy:'mtls',...pins,allowed_sources:[]});
const certificatePin=()=>({version:1,hostname,origin_sni:originSni,server_cert_sha256:pins.server_cert_sha256});
const address=nativeAddress('20010db812345678');
const proof={mtls_verified:true,origin_header_verified:true};
function fixture(t,{native=false}={}){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-origin-files-'));
 t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const mapped=file=>typeof file==='number'?file:path.join(root,file);
 const mappedFs={constants:fs.constants};
 for(const name of ['openSync','readFileSync','writeFileSync','mkdirSync','lstatSync','chmodSync','unlinkSync'])mappedFs[name]=(...args)=>fs[name](mapped(args[0]),...args.slice(1));
 for(const name of ['fstatSync','closeSync','fsyncSync'])mappedFs[name]=(...args)=>fs[name](...args);
 mappedFs.renameSync=(a,b)=>fs.renameSync(mapped(a),mapped(b));
 mappedFs.linkSync=(a,b)=>fs.linkSync(mapped(a),mapped(b));
 const write=(file,value,mode=0o600)=>{fs.mkdirSync(path.dirname(mapped(file)),{recursive:true,mode:0o700});fs.writeFileSync(mapped(file),typeof value==='string'?value:JSON.stringify(value),{mode});fs.chmodSync(mapped(file),mode);};
 const read=file=>JSON.parse(fs.readFileSync(mapped(file),'utf8'));
 write(paths.policy,policy());write(paths.certificatePin,certificatePin());write(paths.manifest,manifest());
 for(const [file,key] of [[paths.chain,'chain'],[paths.key,'key'],[paths.clientCa,'clientCa'],[paths.healthCert,'healthCert'],[paths.healthKey,'healthKey']])write(file,material[key]);
 const clock={now:Date.now()},state={available:true,owned:true,guard:guardDefinition('usb0',4),probe:()=>proof};
 const children=[],calls=[],logs=[],delays=[];
 const run=(bin,args)=>{
  calls.push([bin,args]);
  if(bin==='nft'){if(state.guardError)throw Error('nft unavailable');return state.guard;}
  if(bin==='ip')return JSON.stringify([{ifname:'usb0',addr_info:[{family:'inet6',local:address,prefixlen:128,scope:'global',flags:[],preferred_life_time:180,valid_life_time:180}]}]);
  return '';
 };
 const spawn=(bin,args,options)=>{
  const child=new EventEmitter();child.pid=43000+children.length;child.signals=[];
  child.kill=signal=>{child.signals.push(signal);child.emit('exit',0,signal);return true;};
  children.push(child);calls.push([bin,args,options]);return child;
 };
 write(statusPath,{phase:'online',updated:clock.now,prefix:'2001:db8:1234:5678::/64',address,quota:{enabled:true,limit:'1000',used:'10',blocked:false}});
 const options={fs:mappedFs,now:()=>clock.now,run,spawn,probe:(o,opts)=>state.probe(o,opts),ownsListener:()=>state.owned,
  wait:async ms=>{delays.push(ms);},log:line=>logs.push(line),...(native?{}:{select:()=>{if(!state.available)throw Error('secret internal failure');return address;}})};
 return {root,mapped,fs:mappedFs,clock,state,children,calls,logs,delays,write,read,options,controller:new LuckyOrigin(options),exists:file=>fs.existsSync(mapped(file))};
}

test('fixed manifest/policy schemas reject injection, other hosts, allowlists and missing pins',()=>{
 assert.equal(hostname,'cpe.lucky.jmsu.top');assert.equal(originSni,'cpe-origin.jmsu.top');
 assert.equal(validateManifest(manifest()).hostname,hostname);assert.equal(validatePolicy({enabled:false}),null);
 for(const patch of [{version:2},{hostname:'cpe.jmsu.top'},{origin_sni:'bad.invalid'},{origin_sni:hostname},{origin_header_secret:'a'.repeat(64)+'\n'},{origin_header_secret:'A'.repeat(64)},
  {username:'admin'},{password:'short'},{password:'x'.repeat(24)+'\n'},{password:'é'.repeat(24)},{lucky_rule_key:''},{ddns_task_key:'x\ny'}])assert.throws(()=>validateManifest({...manifest(),...patch}),/CPE public origin unavailable/);
 for(const patch of [{hostname:'cpe.jmsu.top'},{source_policy:'allowlist'},{allowed_sources:['::/0']},{client_ca_sha256:undefined},{server_cert_sha256:'A'.repeat(64)},{enabled:'true'}])assert.throws(()=>validatePolicy({...policy(),...patch}));
 assert.equal(validatePolicy({...policy(),server_cert_sha256:'b'.repeat(64)},certificatePin()).server_cert_sha256,pins.server_cert_sha256);
 assert.equal(validatePolicy({...policy(),server_cert_sha256:undefined},certificatePin()).server_cert_sha256,pins.server_cert_sha256);
 for(const pin of [null,{}, {...certificatePin(),version:2},{...certificatePin(),hostname:'bad.invalid'},
  {...certificatePin(),origin_sni:hostname},{...certificatePin(),server_cert_sha256:'b'.repeat(63)}])assert.throws(()=>validatePolicy(policy(),pin));
});
test('real X509 parsing checks DER pins, SAN, key pairs, dedicated CA, health issuer and strict72h expiry',()=>{
 assert.deepEqual(validateMaterials(material,policy(),Date.now()),pins);
 for(const patch of [{key:material.healthKey},{healthKey:material.key},{clientCa:material.healthCert},{healthCert:material.chain},
  {chain:certFile('wrong.pem')+material.clientCa},{chain:'not a certificate'},{chain:material.chain+'not PEM'}])assert.throws(()=>validateMaterials({...material,...patch},policy(),Date.now()));
 assert.throws(()=>validateMaterials(material,{...policy(),server_cert_sha256:'f'.repeat(64)},Date.now()));
 assert.throws(()=>validateMaterials(material,{...policy(),client_ca_sha256:'f'.repeat(64)},Date.now()));
 const cert=new X509Certificate(material.chain),end=Math.min(...[material.chain,material.clientCa,material.healthCert].map(pem=>Date.parse(new X509Certificate(pem).validTo))),begin=Date.parse(cert.validFrom);
 assert.throws(()=>validateMaterials(material,policy(),end-72*3600000));
 assert.deepEqual(validateMaterials(material,policy(),end-72*3600000-1000),pins);
 assert.throws(()=>validateMaterials(material,policy(),begin-1));
});
test('root files reject final symlinks, non-root ownership, writable public files and readable secrets',t=>{
 const f=fixture(t);assert.ok(readRootFile(f.fs,paths.key,{secret:true}).includes('PRIVATE KEY'));
 fs.chmodSync(f.mapped(paths.manifest),0o644);assert.throws(()=>loadOrigin(f.options));fs.chmodSync(f.mapped(paths.manifest),0o600);
 fs.chmodSync(f.mapped(paths.chain),0o666);assert.throws(()=>loadOrigin(f.options));fs.chmodSync(f.mapped(paths.chain),0o600);
 const fake={...f.fs,fstatSync:fd=>({...fs.fstatSync(fd),isFile:()=>true,uid:1000})};assert.throws(()=>loadOrigin({...f.options,fs:fake}));
 fs.unlinkSync(f.mapped(paths.key));fs.symlinkSync(path.join(dir,'server.key'),f.mapped(paths.key));assert.throws(()=>loadOrigin(f.options));
});
test('missing, malformed, writable, symlinked or mismatched separate pin revokes readiness',async t=>{
 for(const mutate of [f=>fs.unlinkSync(f.mapped(paths.certificatePin)),f=>f.write(paths.certificatePin,'not JSON'),
  f=>fs.chmodSync(f.mapped(paths.certificatePin),0o666),f=>f.write(paths.certificatePin,{...certificatePin(),origin_sni:hostname}),
  f=>{fs.unlinkSync(f.mapped(paths.certificatePin));fs.symlinkSync(f.mapped(paths.policy),f.mapped(paths.certificatePin));}]){
  const f=fixture(t);assert.equal(await f.controller.tick(),true);mutate(f);
  assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.deepEqual(f.children[0].signals,['SIGTERM']);
 }
});
test('disabled or absent configuration clears stale readiness without spawning or reading secrets',async t=>{
 for(const absent of [false,true]){
  const f=fixture(t);f.write(paths.ready,{ready:true});if(absent)fs.unlinkSync(f.mapped(paths.policy));else f.write(paths.policy,{enabled:false});
  fs.unlinkSync(f.mapped(paths.manifest));assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.equal(f.children.length,0);assert.equal(f.calls.length,0);
 }
});
test('HAProxy config is IPv6-only, mandatory mTLS, exact full header count/match and does not alter auth/cookies',()=>{
 const config=haproxyConfig(manifest());
 assert.match(config,/bind :::18443 v6only ssl .* ca-file .* verify required ssl-min-ver TLSv1\.2/);
 assert.match(config,/ssl_fc_sni -m str cpe-origin\.jmsu\.top/);assert.match(config,/req\.fhdr\(Host\),lower -m str cpe\.lucky\.jmsu\.top/);
 assert.match(config,/noreuseport/);assert.match(config,/no log/);assert.match(config,/req\.fhdr_cnt\(X-CPE-Origin\) eq 1/);assert.match(config,/req\.fhdr\(X-CPE-Origin\) -m str a{64}/);
 assert.match(config,/http-request del-header X-CPE-Origin/);assert.match(config,/set-header X-Forwarded-Proto https/);assert.match(config,/server lucky 127\.0\.0\.1:16801/);
 assert.doesNotMatch(config,/http-request (?:set-header|del-header|replace-header) (?:Authorization|Cookie)|cpe-temp|TestFixture|log stdout|daemon|ca-ignore-err|crt-ignore-err/);
 assert.equal(config.split('\n').filter(line=>line.includes('http-response replace-header Set-Cookie')).length,2);
 assert.ok(config.includes('LuckyWebAuthorization_[^=;[:space:]]+'));
 assert.match(config,/SameSite=Lax/);
});
test('optional API registry is fixed, strict0600, and never changes UDX readiness when absent/unsafe/disabled',async t=>{
 const service={...defaultApiService(),enabled:true};assert.equal(validateApiService(service).publicHost,apiHostname);
 assert.equal(validateApiService({...service,allowedRequests:service.allowedRequests.map(x=>({path:x.path,method:x.method})).reverse()}).enabled,true);
 for(const patch of [{publicHost:'other.lucky.jmsu.top'},{upstream:'http://192.168.13.1:22'},{listen:'0.0.0.0:16802'},
  {allowedRequests:[{method:'GET',path:'/management'}]},{apiKey:'ForbiddenRawSecret'},{version:2},{enabled:1}])assert.throws(()=>validateApiService({...service,...patch}));
 for(const mutate of [f=>{},f=>f.write(apiPaths.config,defaultApiService()),f=>f.write(apiPaths.config,'malformed'),
  f=>f.write(apiPaths.config,service,0o644),f=>f.write(apiPaths.config,{...service,publicHost:'foreign.invalid'}),
  f=>{f.write(apiPaths.config,service);fs.unlinkSync(f.mapped(apiPaths.config));fs.symlinkSync(f.mapped(paths.manifest),f.mapped(apiPaths.config));}]){
  const f=fixture(t);mutate(f);assert.equal(await f.controller.tick(),true);assert.equal(f.read(paths.apiReady).ready,false);
  assert.ok(!fs.readFileSync(f.mapped(paths.config),'utf8').includes('backend cpe_lucky_api'));
 }
});
test('API backend/probe failure and administrator disables remove only the API route',async t=>{
 const f=fixture(t);f.write(apiPaths.config,{...defaultApiService(),enabled:true});
 let backend=true,route=true;
 const controller=new LuckyOrigin({...f.options,apiCheck:async()=>backend,probeApi:async()=>route});
 assert.equal(await controller.tick(),true);assert.equal(f.read(paths.apiReady).ready,true);
 assert.match(fs.readFileSync(f.mapped(paths.config),'utf8'),/backend cpe_lucky_api/);
 backend=false;assert.equal(await controller.tick(),true);assert.equal(f.read(paths.apiReady).ready,false);
 backend=true;route=false;assert.equal(await controller.tick(),true);assert.equal(f.read(paths.apiReady).ready,false);
 route=true;f.write(apiPaths.config,defaultApiService());assert.equal(await controller.tick(),true);assert.equal(f.read(paths.apiReady).ready,false);
 f.write(apiPaths.config,{...defaultApiService(),enabled:true});
 f.state.probe=()=>{f.write(apiPaths.config,defaultApiService());return proof;};
 assert.equal(await controller.tick(),true);assert.equal(f.read(paths.apiReady).ready,false);
 f.state.probe=()=>{throw Error('UDX failed');};assert.equal(await controller.tick(),false);assert.equal(f.exists(paths.apiReady),false);
 await controller.stop();
});
test('optional ROM API restore is validated, atomic no-clobber and preserves existing disable or unsafe files',t=>{
 const service={...defaultApiService(),enabled:true};
 const f=fixture(t);f.write(apiPaths.romConfig,service);fs.mkdirSync(f.mapped('/etc/cpe5g-lucky'),{recursive:true,mode:0o700});
 assert.deepEqual(restoreApiService({fs:f.fs}),service);assert.deepEqual(f.read(apiPaths.config),service);
 assert.equal(fs.statSync(f.mapped(apiPaths.config)).mode&0o777,0o600);
 f.write(apiPaths.config,defaultApiService());assert.equal(restoreApiService({fs:f.fs}).enabled,false);assert.equal(f.read(apiPaths.config).enabled,false);
 for(const mutation of [g=>g.write(apiPaths.romConfig,'malformed'),g=>g.write(apiPaths.romConfig,service,0o644),
  g=>g.write(apiPaths.romConfig,{...service,upstream:'http://127.0.0.1:22'}),g=>{g.write(apiPaths.romConfig,service);fs.chmodSync(g.mapped('/rom/etc/cpe5g-lucky'),0o777);},
  g=>{g.write(apiPaths.romConfig,service);fs.unlinkSync(g.mapped(apiPaths.romConfig));fs.symlinkSync(g.mapped(paths.manifest),g.mapped(apiPaths.romConfig));}]){
  const g=fixture(t);mutation(g);assert.equal(restoreApiService({fs:g.fs}),null);assert.equal(g.exists(apiPaths.config),false);
 }
 const g=fixture(t);g.write(apiPaths.romConfig,service);g.write(apiPaths.config,'administrator invalid text');
 assert.equal(restoreApiService({fs:g.fs}),null);assert.equal(fs.readFileSync(g.mapped(apiPaths.config),'utf8'),'administrator invalid text');
 fs.unlinkSync(g.mapped(apiPaths.config));
 const real=g.fs.linkSync;g.fs.linkSync=(a,b)=>{g.write(b,defaultApiService());return real(a,b);};
 assert.equal(restoreApiService({fs:g.fs}).enabled,false);assert.equal(g.read(apiPaths.config).enabled,false);
});
function requestFixture({change,fail}={}){
 const calls=[];const expected='Basic '+Buffer.from(manifest().username+':'+manifest().password).toString('base64');
 const request=async options=>{
  calls.push(options);if(fail)throw Error('raw secret failure');
  let result;
  const headers=options.headers||[],secrets=headers.filter(([key])=>key==='X-CPE-Origin'),authorization=headers.find(([key])=>key==='Authorization')?.[1];
  if(options.client===false)result={tlsDenied:true};
  else if(secrets.length!==1||secrets[0][1]!==manifest().origin_header_secret||headers.some(([key])=>key==='Host'))result={status:403,body:''};
  else if(authorization!==expected||options.path==='/api/netif/list')result={status:401,body:''};
  else result={status:200,body:options.path==='/api/auth/status'?JSON.stringify({logged_in:false,auth_required:true}):'<html>UDX login</html>'};
  return change?change(options,result):result;
 };
 return {request,calls};
}
test('probes prove TLS requirement, header negatives, all-path Lucky auth and separate UDX login',async()=>{
 const f=requestFixture();assert.deepEqual(await probeOrigin({manifest:manifest(),material,pins},{request:f.request}),proof);
 assert.equal(f.calls.length,13);assert.ok(f.calls.some(call=>call.path==='/api/auth/status'));assert.ok(f.calls.some(call=>call.path==='/api/netif/list'));
 for(const change of [
  (o,r)=>o.client===false?{status:403}:r,
  (o,r)=>o.client===false?{status:0}:r,
  (o,r)=>o.headers.filter(([k])=>k==='X-CPE-Origin').length===2?{status:200}:r,
  (o,r)=>!o.headers.some(([k])=>k==='X-CPE-Origin')?{status:200}:r,
  (o,r)=>o.path==='/api/auth/status'&&r.status===200?{status:200,body:JSON.stringify({logged_in:true,auth_required:false})}:r,
  (o,r)=>o.path==='/api/netif/list'?{status:200}:r,
  (o,r)=>o.path?.startsWith('/static/')?{status:200}:r,
  (o,r)=>r.status===200?{status:200,body:''}:r
 ])await assert.rejects(probeOrigin({manifest:manifest(),material,pins},{request:requestFixture({change}).request}),/CPE public origin unavailable/);
 await assert.rejects(probeOrigin({manifest:manifest(),material,pins},{request:requestFixture({fail:true}).request}));
});
test('owned subprocess/config validation precede readiness; config/crt600 runtime700 and refresh keeps exact address/pins',async t=>{
 const f=fixture(t);assert.equal(await f.controller.tick(),true);
 assert.deepEqual(f.read(paths.ready),{ready:true,hostname,source_policy:'mtls',port:originPort,address,updated:f.clock.now,...pins,...proof});
 const subprocesses=f.calls.filter(call=>call[0]==='/usr/sbin/haproxy');
 assert.deepEqual(subprocesses.map(call=>call.slice(0,2)),[['/usr/sbin/haproxy',['-c','-f',paths.config]],['/usr/sbin/haproxy',['-db','-f',paths.config]]]);
 assert.deepEqual(subprocesses[1][2].stdio,['ignore','ignore','ignore']);
 for(const file of [paths.config,paths.serverPem,paths.runtimeCa,paths.ready])assert.equal(fs.statSync(f.mapped(file)).mode&0o777,0o600);
 assert.equal(fs.statSync(f.mapped(paths.runtime)).mode&0o777,0o700);
 f.clock.now+=5000;assert.equal(await f.controller.tick(),true);assert.equal(f.read(paths.ready).updated,f.clock.now);assert.equal(f.children.length,1);
 await f.controller.stop();assert.equal(f.exists(paths.ready),false);assert.equal(f.exists(paths.serverPem),false);assert.deepEqual(f.children[0].signals,['SIGTERM']);
});
test('manifest/material changes remove readiness and replace only the owned child',async t=>{
 const f=fixture(t);await f.controller.tick();const first=f.controller.child;
 const next=manifest();next.origin_header_secret='b'.repeat(64);f.write(paths.manifest,next);
 f.state.probe=()=>{assert.equal(f.exists(paths.ready),false);return proof;};assert.equal(await f.controller.tick(),true);
 assert.deepEqual(first.signals,['SIGTERM']);assert.equal(f.children.length,2);assert.notEqual(f.controller.child,first);
 f.write(paths.key,material.healthKey);assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.deepEqual(f.children[1].signals,['SIGTERM']);
 assert.ok(f.logs.every(line=>!line.includes('a'.repeat(64))&&!line.includes('TestFixture')));
});
test('certificate renewal requires transaction-owned new DER pin and never rewrites administrator policy',async t=>{
 const f=fixture(t);await f.controller.tick();
 const approvedPolicy=f.read(paths.policy);
 const chain=certFile('renewed.pem')+material.clientCa;
 f.write(paths.chain,chain);f.write(paths.key,certFile('renewed.key'));
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.equal(f.children.length,1);
 const next={...certificatePin(),server_cert_sha256:fingerprint(chain)};f.write(paths.certificatePin,next);
 assert.equal(await f.controller.tick(),true);assert.equal(f.read(paths.ready).server_cert_sha256,next.server_cert_sha256);assert.equal(f.children.length,2);
 assert.deepEqual(f.read(paths.policy),approvedPolicy);
 f.state.probe=()=>{f.write(paths.policy,{...approvedPolicy,enabled:false});return proof;};
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.equal(f.read(paths.policy).enabled,false);
 assert.equal(await f.controller.tick(),false);assert.equal(f.children.length,2);
});
test('certificate and private restoration journals revoke readiness during probes/publication',async t=>{
 for(const journal of [paths.deployJournal,paths.restoreJournal]){
 const f=fixture(t);await f.controller.tick();fs.mkdirSync(f.mapped(journal));
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.deepEqual(f.children[0].signals,['SIGTERM']);
 fs.rmdirSync(f.mapped(journal));assert.equal(await f.controller.tick(),true);
 f.state.probe=()=>{fs.mkdirSync(f.mapped(journal));return proof;};
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);
 fs.rmdirSync(f.mapped(journal));f.state.probe=()=>proof;
 const rename=f.fs.renameSync;f.fs.renameSync=(a,b)=>{rename(a,b);if(b===paths.ready)fs.mkdirSync(f.mapped(journal));};
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);
 }
});
test('native selector rejects stale status, quota exhaustion and address loss without touching controller files',async t=>{
 const f=fixture(t,{native:true});assert.equal(await f.controller.tick(),true);
 const status=f.read(statusPath);f.clock.now+=45001;
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.deepEqual(f.read(statusPath),status);
 f.clock.now=Date.now();status.updated=f.clock.now;status.quota={enabled:true,limit:'1000',used:'1000',blocked:true};f.write(statusPath,status);
 assert.equal(await f.controller.tick(),false);assert.equal(f.children.length,1);assert.deepEqual(f.read(statusPath),status);
});
test('changed policy/pins, probe failure and missing exact proof flags never publish readiness',async t=>{
 for(const mutate of [f=>f.write(paths.certificatePin,{...certificatePin(),server_cert_sha256:'b'.repeat(64)}),f=>f.write(paths.policy,{...policy(),client_ca_sha256:'b'.repeat(64)}),f=>{f.state.available=false;},
  f=>{f.state.probe=()=>{throw Error('raw secret error');};},f=>{f.state.probe=()=>({mtls_verified:true});},f=>{f.state.probe=()=>({mtls_verified:'true',origin_header_verified:true});}]){
  const f=fixture(t);await f.controller.tick();mutate(f);assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.ok(f.logs.every(line=>!line.includes('raw secret')));
 }
});
test('configuration/prefix changes while probing cannot leave stale readiness',async t=>{
 for(const mutation of [f=>f.write(paths.manifest,{...manifest(),password:'DifferentFixtureOnlyLongPassword!'}),f=>{f.state.available=false;},
  f=>f.write(paths.certificatePin,JSON.stringify(certificatePin(),null,2))]){
  const f=fixture(t);f.state.probe=()=>{mutation(f);return proof;};assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);
 }
});
test('child exit clears readiness immediately and restarts after fresh probes',async t=>{
 const f=fixture(t);await f.controller.tick();f.controller.child.emit('exit',1);assert.equal(f.exists(paths.ready),false);
 assert.equal(await f.controller.tick(),true);assert.equal(f.children.length,2);assert.deepEqual(f.children[0].signals,[]);
});
test('foreign listener cannot create readiness and no foreign process/PID is signaled',async t=>{
 const f=fixture(t);const foreign={pid:1234,signals:[],kill(s){this.signals.push(s);}};f.state.owned=false;
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.deepEqual(foreign.signals,[]);assert.deepEqual(f.children[0].signals,['SIGTERM']);
 const proc={pid:456};const table='  sl  local_address rem_address st tx_queue tr retrnsmt uid timeout inode\n 0: 00000000000000000000000000000000:480B 00000000000000000000000000000000:0000 0A 0:0 0:0 0 0 0 999\n';
 const procFs={readFileSync:()=>table,readdirSync:()=>['3'],readlinkSync:()=> 'socket:[999]'};
 assert.equal(ownedListener(proc,procFs),true);assert.equal(ownedListener(proc,{...procFs,readlinkSync:()=> 'socket:[123]'}),false);assert.equal(ownedListener({pid:'456'},procFs),false);
});
test('owned v4 native guard is required; absent/foreign/v1-v3 cannot start or maintain the origin',async t=>{
 const valid=guardDefinition('usb0',4);
 assert.equal(ownedGuard((bin,args)=>{assert.equal(bin,'nft');assert.deepEqual(args,['list','table','inet','cpe6_guard']);return valid;}),true);
 const invalid=['',null,...[1,2,3].map(version=>guardDefinition('usb0',version)),valid.replace('counter drop','counter accept'),guardDefinition('wan',4)];
 for(const text of invalid){
  const f=fixture(t);f.state.guard=text;f.write(paths.ready,{ready:true});let probes=0;f.state.probe=()=>{probes++;return proof;};
  assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.equal(f.children.length,0);assert.equal(probes,0);
 }
 const f=fixture(t);await f.controller.tick();f.state.guardError=true;
 assert.equal(await f.controller.tick(),false);assert.equal(f.exists(paths.ready),false);assert.deepEqual(f.children[0].signals,['SIGTERM']);
});
test('guard is rechecked after config validation, after network probes and after ready publication',async t=>{
 const before=fixture(t),originalRun=before.options.run;
 before.options.run=(bin,args)=>{const result=originalRun(bin,args);if(bin==='/usr/sbin/haproxy')before.state.guard=guardDefinition('usb0',3);return result;};
 const controller=new LuckyOrigin(before.options);assert.equal(await controller.tick(),false);assert.equal(before.children.length,0);assert.equal(before.exists(paths.ready),false);
 const during=fixture(t);during.state.probe=()=>{during.state.guard=guardDefinition('usb0',3);return proof;};
 assert.equal(await during.controller.tick(),false);assert.equal(during.exists(paths.ready),false);assert.deepEqual(during.children[0].signals,['SIGTERM']);
 const after=fixture(t),rename=after.fs.renameSync;
 after.fs.renameSync=(a,b)=>{rename(a,b);if(b===paths.ready)after.state.guard='';};
 assert.equal(await after.controller.tick(),false);assert.equal(after.exists(paths.ready),false);assert.deepEqual(after.children[0].signals,['SIGTERM']);
});
test('validation failure does not spawn; shutdown aborts pending probes, cleans files and never reopens',async t=>{
 const invalid=fixture(t);invalid.options.run=bin=>{if(bin==='nft')return guardDefinition('usb0',4);throw Error('haproxy output includes secret');};const failed=new LuckyOrigin(invalid.options);
 assert.equal(await failed.tick(),false);assert.equal(invalid.children.length,0);assert.equal(invalid.exists(paths.ready),false);
 const f=fixture(t);let probing;const started=new Promise(resolve=>{probing=resolve;});
 f.state.probe=(origin,{signal})=>new Promise((resolve,reject)=>{probing();signal.addEventListener('abort',()=>reject(Error('cancelled')),{once:true});});
 const pending=f.controller.tick();await Promise.race([started,pending.then(()=>assert.fail('supervisor did not reach the pending probe'))]);
 const stopped=f.controller.stop();assert.equal(await pending,false);await stopped;
 assert.equal(f.exists(paths.ready),false);assert.equal(f.exists(paths.config),false);assert.equal(await f.controller.tick(),false);assert.deepEqual(f.children[0].signals,['SIGTERM']);
});
test('shutdown is bounded and escalates SIGTERM to SIGKILL only for the owned child',async t=>{
 const f=fixture(t);await f.controller.tick();const child=f.controller.child;
 child.kill=signal=>{child.signals.push(signal);if(signal==='SIGKILL')child.emit('exit',0,signal);return true;};
 await f.controller.stop();assert.deepEqual(child.signals,['SIGTERM','SIGKILL']);assert.ok(f.delays.includes(1500));assert.equal(f.exists(paths.ready),false);
});
test('aborted loop removes readiness and import has no CLI side effects',async t=>{
 const f=fixture(t),abort=new AbortController();let waits=0;
 await originMain({...f.options,signal:abort.signal,wait:async ms=>{waits++;if(ms===5000)abort.abort();}});
 assert.ok(waits>0);assert.equal(f.exists(paths.ready),false);assert.deepEqual(f.children[0].signals,['SIGTERM']);
 const module=new URL('../Scripts/cpe5g-ipv6/lucky-origin.mjs',import.meta.url).href;
 assert.equal(execFileSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(module)}); process.stdout.write('import-only');`],{encoding:'utf8'}),'import-only');
});
test('real TLS transport proves single default/overridden Host, mandatory client cert and duplicate secret rejection',async t=>{
 const captured=[];
 const server=tls.createServer({key:material.key,cert:material.chain,ca:material.clientCa,requestCert:true,rejectUnauthorized:true},socket=>{
  let request='',complete=false;socket.on('data',bytes=>{if(complete)return;request+=bytes.toString();if(!request.includes('\r\n\r\n'))return;complete=true;
   const hosts=request.split('\r\n').filter(line=>/^host:/i.test(line));
   const secrets=request.split('\r\n').filter(line=>line.startsWith('X-CPE-Origin:'));
   captured.push({hosts,secrets});
   if(hosts.length!==1)return socket.end('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
   if(hosts[0].slice(hosts[0].indexOf(':')+1).trim()!==hostname||secrets.length!==1||secrets[0]!=='X-CPE-Origin: '+manifest().origin_header_secret)return socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
   const body=JSON.stringify({logged_in:false,auth_required:true});socket.end('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n'+Buffer.byteLength(body).toString(16)+'\r\n'+body+'\r\n0\r\n\r\n');
  });
 });
 server.on('tlsClientError',()=>{});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(originPort,'::1',resolve);});
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 const secret=['X-CPE-Origin',manifest().origin_header_secret];
 assert.deepEqual(await tlsRequest({material,pins,client:false,headers:[secret]}),{tlsDenied:true});
 assert.equal((await tlsRequest({material,pins,headers:[secret,secret]})).status,403);
 assert.deepEqual(captured.at(-1).hosts,['Host: '+hostname]);assert.equal(captured.at(-1).secrets.length,2);
 const result=await tlsRequest({material,pins,headers:[secret]});assert.equal(result.status,200);assert.deepEqual(JSON.parse(result.body),{logged_in:false,auth_required:true});
 assert.deepEqual(captured.at(-1).hosts,['Host: '+hostname]);
 for(const name of ['Host','hOsT']){
  assert.equal((await tlsRequest({material,pins,headers:[secret,[name,'unmatched.invalid']]})).status,403);
  assert.deepEqual(captured.at(-1).hosts,[name+': unmatched.invalid']);assert.equal(captured.at(-1).secrets.length,1);
 }
 await assert.rejects(tlsRequest({material,pins:{...pins,server_cert_sha256:'f'.repeat(64)},headers:[secret]}),/CPE public origin unavailable/);
 const abort=new AbortController();abort.abort();await assert.rejects(tlsRequest({material,pins,headers:[secret],signal:abort.signal}));
});

let cookieTestHaproxy=process.env.CPE_TEST_HAPROXY;
if(!cookieTestHaproxy){try{cookieTestHaproxy=execFileSync('which',['haproxy'],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();}catch{}}
test('real HAProxy API rejects ambiguous targets/Host and preserves Bearer, large bodies and incremental SSE',
 {skip:!cookieTestHaproxy},async t=>{
 const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-haproxy-api-')),received=[];
 let child;
 const udx=http.createServer((request,response)=>{response.writeHead(200,{'set-cookie':'LuckyWebAuthorization_udx=x; Path=/'});response.end('UDX');});
 const api=http.createServer((request,response)=>{
  let body='';request.on('data',part=>body+=part);request.on('end',()=>{
   received.push({authorization:request.headers.authorization,path:request.url,body,secret:request.headers['x-cpe-origin']});
   if(request.headers.authorization!=='Bearer FixtureLimitedAPIKey')return response.writeHead(401).end('unauthorized');
   if(request.method==='GET')return response.writeHead(200,{'content-type':'application/json','set-cookie':'LuckyWebAuthorization_api=x; Path=/'}).end('{"data":[]}');
   response.writeHead(200,{'content-type':'text/event-stream'});response.flushHeaders();
   response.write('data: {"part":1}\n\n');
   setTimeout(()=>response.write(': heartbeat\n\ndata: {"part":2}\n\n'),60);
   setTimeout(()=>response.end('data: [DONE]\n\n'),120);
  });
 });
 t.after(async()=>{
  if(child&&child.exitCode===null&&child.signalCode===null)await new Promise(resolve=>{const timer=setTimeout(()=>child.kill('SIGKILL'),1500);child.once('exit',()=>{clearTimeout(timer);resolve();});child.kill('SIGTERM');});
  await Promise.all([new Promise(resolve=>udx.close(resolve)),new Promise(resolve=>api.close(resolve))]);fs.rmSync(temporary,{recursive:true,force:true});
 });
 await Promise.all([udx,api].map(server=>new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);} )));
 const reservation=net.createServer();await new Promise(resolve=>reservation.listen(0,'::1',resolve));
 const port=reservation.address().port;await new Promise(resolve=>reservation.close(resolve));
 const serverPem=path.join(temporary,'server.pem'),ca=path.join(temporary,'ca.pem'),configuration=path.join(temporary,'haproxy.cfg');
 fs.writeFileSync(serverPem,material.chain+'\n'+material.key,{mode:0o600});fs.writeFileSync(ca,material.clientCa,{mode:0o600});
 const config=haproxyConfig(manifest(),{...defaultApiService(),enabled:true}).replace(paths.serverPem,serverPem).replace(paths.runtimeCa,ca).replaceAll(paths.httpSocket,path.join(temporary,'http.sock'))
  .replace('bind :::18443','bind [::1]:'+port).replace('127.0.0.1:16801','127.0.0.1:'+udx.address().port).replace('127.0.0.1:16802','127.0.0.1:'+api.address().port);
 fs.writeFileSync(configuration,config,{mode:0o600});execFileSync(cookieTestHaproxy,['-c','-f',configuration],{stdio:['ignore','pipe','pipe']});
 child=spawn(cookieTestHaproxy,['-db','-f',configuration],{stdio:['ignore','ignore','ignore']});
 await new Promise((resolve,reject)=>{
  let n=0;const connect=()=>{if(child.exitCode!==null)return reject(Error('fixture HAProxy exited'));
   const socket=net.createConnection({host:'::1',port});socket.once('connect',()=>{socket.destroy();resolve();});
   socket.once('error',()=>{socket.destroy();if(++n>100)return reject(Error('fixture startup timeout'));setTimeout(connect,10);});};child.once('error',reject);connect();
 });
 const request=({method='GET',path='/v1/models',host=apiHostname,authorization,body='',extra={},sni=originSni,client=true}={})=>new Promise((resolve,reject)=>{
  const req=https.request({hostname:'::1',port,servername:sni,ca:material.clientCa,rejectUnauthorized:sni===originSni,
   ...(client?{cert:material.healthCert,key:material.healthKey}:{}),agent:false,method,path,
   headers:{Host:host,'X-CPE-Origin':manifest().origin_header_secret,...(authorization?{Authorization:authorization}:{}),...extra}},response=>{
   const chunks=[];response.on('data',bytes=>chunks.push({at:Date.now(),text:bytes.toString()}));
   response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,chunks,body:chunks.map(x=>x.text).join('')}));
  });req.once('error',reject);req.setTimeout(3000,()=>req.destroy(Error('fixture timeout')));req.end(body);
 });
 assert.equal((await request()).status,401);assert.equal((await request({authorization:'Bearer IncorrectKey'})).status,401);
 for(const [method,path] of [['GET','/management'],['GET','/key/list'],['GET','/debug'],['GET','/v1/responses'],['POST','/v1/models'],
  ['DELETE','/v1/models'],['GET','/V1/models'],['GET','/v1//models'],['GET','/v1/%6dodels'],
  ['GET','/v1/../v1/models'],['GET','/v1/models?admin=1'],['GET','http://ai.lucky.jmsu.top/v1/models']]){
  assert.equal((await request({method,path,authorization:'Bearer FixtureLimitedAPIKey'})).status,403,method+' '+path);
 }
 for(const options of [{host:'foreign.invalid'},{host:apiHostname+':18443'},{extra:{'X-CPE-Origin':'wrong'}}])assert.equal((await request(options)).status,403);
 await assert.rejects(request({sni:'wrong.invalid'}));
 await assert.rejects(request({client:false}));
 const models=await request({authorization:'Bearer FixtureLimitedAPIKey'});assert.equal(models.status,200);
 assert.deepEqual(models.headers['set-cookie'],['LuckyWebAuthorization_api=x; Path=/']);assert.equal(models.headers['cache-control'],'no-store, no-transform');
 assert.ok(!received.at(-1).secret);assert.equal(received.at(-1).authorization,'Bearer FixtureLimitedAPIKey');
 const largeBody=JSON.stringify({model:'approved',input:'x'.repeat(32768),stream:true});
 for(const path of ['/v1/chat/completions','/v1/responses']){
  const stream=await request({method:'POST',path,authorization:'Bearer FixtureLimitedAPIKey',body:largeBody,extra:{'content-type':'application/json'}});
  assert.equal(stream.status,200);assert.match(stream.body,/part.*1[\s\S]*heartbeat[\s\S]*part.*2[\s\S]*\[DONE\]/);
  assert.ok(stream.chunks.length>=3);assert.ok(stream.chunks.at(-1).at-stream.chunks[0].at>=70);assert.equal(received.at(-1).body,largeBody);
 }
 const normal=await request({host:hostname,path:'/'});assert.equal(normal.body,'UDX');assert.deepEqual(normal.headers['set-cookie'],['LuckyWebAuthorization_udx=x; Path=/; Secure; SameSite=Lax']);
 const raw=(lines,method='GET')=>new Promise((resolve,reject)=>{
  let bytes='';const socket=tls.connect({host:'::1',port,servername:originSni,ca:material.clientCa,cert:material.healthCert,key:material.healthKey},()=>socket.write(method+' /v1/models HTTP/1.1\r\n'+lines.join('\r\n')+'\r\nConnection: close\r\n\r\n'));
  socket.on('data',data=>bytes+=data.toString());socket.once('end',()=>resolve(Number(bytes.match(/^HTTP\/1\.[01] (\d+)/)?.[1])));socket.once('error',reject);socket.setTimeout(3000,()=>socket.destroy(Error('fixture timeout')));
 });
 const secret='X-CPE-Origin: '+manifest().origin_header_secret;
 assert.ok([400,403,NaN].includes(await raw(['Host: '+apiHostname,'Host: '+apiHostname,secret])));
 assert.equal(await raw(['Host: '+apiHostname,secret,secret]),403);
 assert.equal(await raw(['Host: '+apiHostname,secret,'Authorization: Bearer One','Authorization: Bearer Two']),403);
 assert.equal(await raw(['Host: '+apiHostname,secret,'Authorization: Bearer FixtureLimitedAPIKey'],'get'),403);
});
test('real HAProxy preserves each cookie and Bearer headers while hardening only native Lucky cookies',
 {skip:!cookieTestHaproxy},async t=>{
 const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-haproxy-cookies-'));
 const cookies=[
  'LuckyWebAuthorization_a=ValueOne==; Path=/; HttpOnly',
  'LuckyWebAuthorization_b=ValueTwo; Path=/; HttpOnly; Secure; SameSite=Strict',
  'LuckyWebAuthorization_c=ValueThree; SameSite=Strict; Path=/',
  'LuckyWebAuthorization_d=ValueFour; SECURE; HttpOnly',
  'LuckyWebAuthorization_e=ValueFive; secure; sAmEsItE=None',
  'LuckyWebAuthorization_f=Secure; X-Secure=on; NotSameSite=Strict',
  'LuckyWebAuthorization_g=ValueSeven; Expires=Tue, 06 Oct 2026 07:20:00 GMT; HttpOnly',
  'LuckyWebAuthorization_logout=; Path=/; Max-Age=0; HttpOnly',
  'LuckyWebAuthorization_h=ValueEight; Secure=on; SameSite=Lax',
  'LuckyWebAuthorization_key.with.dot=NamespaceValue; Path=/',
  'udx_session=UnchangedUDXValue; Path=/; HttpOnly',
  'NotLuckyWebAuthorization_x=OtherValue; Path=/',
  'luckywebauthorization_lower=CaseSensitiveOtherCookie; Path=/'
 ];
 const expected=[cookies[0]+'; Secure; SameSite=Lax',cookies[1],cookies[2]+'; Secure',
  cookies[3]+'; SameSite=Lax',cookies[4],cookies[5]+'; Secure; SameSite=Lax',
  cookies[6]+'; Secure; SameSite=Lax',cookies[7]+'; Secure; SameSite=Lax',cookies[8],
  cookies[9]+'; Secure; SameSite=Lax',...cookies.slice(10)];
 let received;
 const backend=http.createServer((request,response)=>{
  received={authorization:request.headers.authorization,cookie:request.headers.cookie};
  response.writeHead(200,{'Set-Cookie':cookies,'content-type':'text/plain'});response.end('cookie fixture');
 });
 let child;
 t.after(async()=>{
  if(child&&child.exitCode===null&&child.signalCode===null){
   await new Promise(resolve=>{const timer=setTimeout(()=>child.kill('SIGKILL'),1500);child.once('exit',()=>{clearTimeout(timer);resolve();});child.kill('SIGTERM');});
  }
  await new Promise(resolve=>backend.close(resolve));fs.rmSync(temporary,{recursive:true,force:true});
 });
 await new Promise((resolve,reject)=>{backend.once('error',reject);backend.listen(0,'127.0.0.1',resolve);});
 const reservation=net.createServer();
 await new Promise((resolve,reject)=>{reservation.once('error',reject);reservation.listen(0,'::1',resolve);});
 const frontendPort=reservation.address().port;await new Promise(resolve=>reservation.close(resolve));
 const serverPem=path.join(temporary,'server.pem'),ca=path.join(temporary,'ca.pem'),configuration=path.join(temporary,'haproxy.cfg');
 fs.writeFileSync(serverPem,material.chain+'\n'+material.key,{mode:0o600});fs.writeFileSync(ca,material.clientCa,{mode:0o600});
 const config=haproxyConfig(manifest()).replace(paths.serverPem,serverPem).replace(paths.runtimeCa,ca).replaceAll(paths.httpSocket,path.join(temporary,'http.sock'))
  .replace('bind :::18443','bind [::1]:'+frontendPort).replace('server lucky 127.0.0.1:16801','server lucky 127.0.0.1:'+backend.address().port);
 fs.writeFileSync(configuration,config,{mode:0o600});
 execFileSync(cookieTestHaproxy,['-c','-f',configuration],{stdio:['ignore','pipe','pipe']});
 child=spawn(cookieTestHaproxy,['-db','-f',configuration],{stdio:['ignore','ignore','pipe']});
 let startupError='';child.stderr.on('data',bytes=>startupError+=bytes.toString());
 await new Promise((resolve,reject)=>{
  let attempts=0;const connect=()=>{
   if(child.exitCode!==null)return reject(Error('fixture HAProxy exited: '+startupError));
   const socket=net.createConnection({host:'::1',port:frontendPort});
   socket.once('connect',()=>{socket.destroy();resolve();});
   socket.once('error',()=>{socket.destroy();if(++attempts>=100)return reject(Error('fixture HAProxy startup timeout'));setTimeout(connect,10);});
  };child.once('error',reject);connect();
 });
 const result=await new Promise((resolve,reject)=>{
  const request=https.request({hostname:'::1',port:frontendPort,servername:originSni,ca:material.clientCa,
   cert:material.healthCert,key:material.healthKey,agent:false,headers:{Host:hostname,Connection:'close',
    'X-CPE-Origin':manifest().origin_header_secret,Authorization:'Bearer FixtureUDXLoginToken',Cookie:'udx_session=PreservedRequestCookie'}},response=>{
   response.resume();response.once('end',()=>resolve({status:response.statusCode,cookies:response.headers['set-cookie']}));
  });request.once('error',reject);request.setTimeout(3000,()=>request.destroy(Error('fixture response timeout')));request.end();
 });
 assert.equal(result.status,200);assert.deepEqual(result.cookies,expected);
 assert.deepEqual(received,{authorization:'Bearer FixtureUDXLoginToken',cookie:'udx_session=PreservedRequestCookie'});
});
