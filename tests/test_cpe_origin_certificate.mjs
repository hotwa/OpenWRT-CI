import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash,X509Certificate} from 'node:crypto';
import fs from 'node:fs';
import {dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {test,after} from 'node:test';
import {OriginCertificateDeployer,certificatePaths,certificatePinFilename,certificateMain,deployOriginCertificate,originHostname,originSni}
 from '../Scripts/cpe5g-ipv6/deploy-origin-certificate.mjs';
import {LuckyPrivateRestorer,privateRestorePaths} from '../Scripts/cpe5g-ipv6/restore-lucky-private.mjs';

// Local OpenSSL fixtures only. No network, firmware, cloud, or device access.
const fixtureRoot=fs.mkdtempSync('/tmp/cpe-origin-cert-test-');
after(()=>fs.rmSync(fixtureRoot,{recursive:true,force:true}));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const pin=cert=>hash(new X509Certificate(cert).raw);
const openssl=args=>execFileSync('/usr/bin/openssl',args,{stdio:['ignore','pipe','pipe']});
const file=(name,data)=>{const path=join(fixtureRoot,name);fs.writeFileSync(path,data,{mode:0o600});return path;};
function authority(name){
 const key=join(fixtureRoot,name+'.key'),crt=join(fixtureRoot,name+'.crt');
 openssl(['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes','-days','40',
  '-subj','/CN='+name,'-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign',
  '-keyout',key,'-out',crt]);return {key,crt};
}
const trusted=authority('trusted-root'),untrusted=authority('untrusted-root');
function issued(name,{issuer=trusted,san=originSni,days='14',ca=false,purpose='serverAuth'}={}){
 const key=join(fixtureRoot,name+'.key'),csr=join(fixtureRoot,name+'.csr'),crt=join(fixtureRoot,name+'.crt');
 openssl(['req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes',
  '-subj','/CN='+originSni,'-keyout',key,'-out',csr]);
 const ext=file(name+'.ext',ca?'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n':
  'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage='+purpose+'\n'+
  (san===null?'':'subjectAltName=DNS:'+san+'\n'));
 openssl(['x509','-req','-in',csr,'-CA',issuer.crt,'-CAkey',issuer.key,'-CAcreateserial','-days',days,
  '-extfile',ext,'-out',crt]);
 return {key,crt,chain:fs.readFileSync(crt)};
}
const intermediate=issued('intermediate',{ca:true,days:'30'});
const current=issued('current'),renewed=issued('renewed',{issuer:intermediate}),health=issued('health',{purpose:'clientAuth'});
renewed.chain=Buffer.concat([renewed.chain,fs.readFileSync(intermediate.crt)]);
const wrong=issued('wrong-san',{san:'unmatched.invalid'}),cnOnly=issued('cn-only',{san:null}),
 wildcard=issued('wildcard',{san:'*.lucky.jmsu.top'}),rogue=issued('rogue',{issuer:untrusted});
const roots=[];
function fixture(){
 const root=fs.mkdtempSync(join(fixtureRoot,'case-'));roots.push(root);
 const paths=Object.fromEntries(Object.entries(certificatePaths).map(([key,path])=>[key,root+path]));
 const put=(path,bytes)=>{fs.mkdirSync(dirname(path),{recursive:true,mode:0o700});fs.writeFileSync(path,bytes,{mode:0o600});};
 const policy={enabled:true,hostname:originHostname,source_policy:'mtls',client_ca_sha256:'c'.repeat(64),
  server_cert_sha256:pin(current.chain),allowed_sources:[],custom:{keep:['exact',17]}};
 const policyBytes=Buffer.from(JSON.stringify(policy,null,1)+'\n');
 put(paths.sourceChain,renewed.chain);put(paths.sourceKey,fs.readFileSync(renewed.key));
 put(join(paths.current,'fullchain.pem'),current.chain);put(join(paths.current,'privkey.pem'),fs.readFileSync(current.key));
 put(join(paths.current,certificatePinFilename),JSON.stringify({version:1,hostname:originHostname,origin_sni:originSni,server_cert_sha256:pin(current.chain)}));
 put(paths.policy,policyBytes);put(paths.manifest,JSON.stringify({version:1,hostname:originHostname,origin_sni:originSni,
  password:'fixture-sensitive-password-value',origin_header_secret:'a'.repeat(64)}));
 put(paths.ready,JSON.stringify({ready:true}));
 const options={paths,caFile:trusted.crt,rootBoundary:fixtureRoot};
 const old={chain:fs.readFileSync(join(paths.current,'fullchain.pem')),key:fs.readFileSync(join(paths.current,'privkey.pem')),
  certificatePin:fs.readFileSync(join(paths.current,certificatePinFilename)),policy:policyBytes};
 return {root,paths,put,options,old,policy,deploy(extra={}){return deployOriginCertificate({...options,...extra});}};
}
function unchanged(f){
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),f.old.chain);
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'privkey.pem')),f.old.key);
 assert.deepEqual(fs.readFileSync(f.paths.policy),f.old.policy);
 if(f.old.certificatePin)assert.deepEqual(fs.readFileSync(join(f.paths.current,certificatePinFilename)),f.old.certificatePin);
 else assert.equal(fs.existsSync(join(f.paths.current,certificatePinFilename)),false);
}
function rejected(f,extra={}){
 let stdout='',stderr='';
 const deployer=new OriginCertificateDeployer({...f.options,...extra});
 assert.equal(certificateMain({deployer,stdout:t=>stdout+=t,stderr:t=>stderr+=t}),1);
 assert.equal(stdout,'');assert.equal(stderr,'CPE origin certificate deployment unavailable\n');unchanged(f);
}
function snapshot(path){
 const stat=fs.lstatSync(path),identity={dev:stat.dev,ino:stat.ino,mode:stat.mode};
 return stat.isDirectory()?{...identity,entries:Object.fromEntries(fs.readdirSync(path).sort().map(name=>[name,snapshot(join(path,name))]))}:
  {...identity,bytes:fs.readFileSync(path)};
}
function interruptedPrivateRestore(f){
 const paths=Object.fromEntries(Object.entries(privateRestorePaths).map(([name,path])=>[name,f.root+path]));
 const manifest={version:1,hostname:originHostname,origin_sni:originSni,lucky_rule_key:'fixture-rule',
  ddns_task_key:'fixture-ddns',ssl_task_key:'fixture-ssl',origin_header_secret:'a'.repeat(64),
  username:'cpe-temp',password:'FixturePrivateRestorePassword!'};
 const policy={...f.policy,client_ca_sha256:pin(fs.readFileSync(trusted.crt))};
 const managed={version:1,domain_suffix:'jmsu.top',
  rule:{RuleKey:manifest.lucky_rule_key,RuleName:'managed-cpe-udx-public-backend',Enable:true,Network:'tcp4',ListenIP:'127.0.0.1',ListenPort:16801,EnableTLS:false,Http3:false,
   DefaultProxy:{WebServiceType:'close',Locations:[]},ProxyList:[{Key:'fixture-child',Enable:true,WebServiceType:'reverseproxy',
    Domains:[originHostname],Locations:['http://192.168.66.1:6677'],EnableBasicAuth:true,WebAuth:true,
    BasicAuthUserList:manifest.username+':'+manifest.password,CacheEnabled:false,OtherParams:{WebAuth:true,BasicAuthRegConf:'',AutoOptionsFirewall:false}}]},
  ddns:{TaskKey:manifest.ddns_task_key,TaskName:'managed-cpe5g-origin-ipv6',Enable:true,TaskType:'IPv6',V4QueryIPEnable:false,V6QueryIPEnable:true,V6QueryIPType:'command',
   V6GetIPScript:'/usr/libexec/cpe5g-ipv6/select-origin-ipv6',DNS:{Name:'alidns',CallAPINetwork:'tcp4',ID:'fixture-dns-id',Secret:'fixture-dns-secret'},
   Records:[{SyncRecordData:{type:'AAAA',fullDomainName:originSni,ipv6Address:'{ipv6Addr}'}}]},
  ssl:{Key:manifest.ssl_task_key,Remark:'cpe5g-origin',Enable:true,AddFrom:'acme',MappingToPath:true,MappingPath:'/etc/lucky/cert-sync/cpe5g-acme',
   MappingChangeScript:'/usr/libexec/cpe5g-ipv6/deploy-origin-certificate',AllSyncClient:false,SyncClientList:[],
   ExtParams:{acmeDNSServer:'alidns',acmeDomains:[originSni],acmeDNSID:'fixture-dns-id',acmeDNSSecret:'fixture-dns-secret',
    acmeCADirURL:'https://acme-v02.api.letsencrypt.org/directory',acmeProxy:''}}};
 const romPath=path=>join(paths.rom,path.slice(f.root.length));
 for(const [name,bytes] of Object.entries({policy:JSON.stringify(policy),manifest:JSON.stringify(manifest),managed:JSON.stringify(managed),
  clientCa:fs.readFileSync(trusted.crt),healthCert:health.chain,healthKey:fs.readFileSync(health.key)}))f.put(romPath(paths[name]),bytes);
 for(const name of ['fullchain.pem','privkey.pem',certificatePinFilename])f.put(join(romPath(paths.current),name),fs.readFileSync(join(paths.current,name)));
 fs.rmSync(paths.current,{recursive:true});fs.unlinkSync(paths.policy);fs.unlinkSync(paths.manifest);
 const options={paths,rootBoundary:fixtureRoot,caFile:trusted.crt},module=new URL('../Scripts/cpe5g-ipv6/restore-lucky-private.mjs',import.meta.url).href;
 const script=`import {LuckyPrivateRestorer} from ${JSON.stringify(module)}; new LuckyPrivateRestorer({...${JSON.stringify(options)},checkpoint:point=>{if(point==='policy')process.kill(process.pid,'SIGKILL');}}).restore();`;
 try{execFileSync(process.execPath,['--input-type=module','-e',script],{stdio:['ignore','pipe','pipe'],timeout:5000});assert.fail('private restore was not interrupted');}
 catch(error){assert.equal(error.signal,'SIGKILL',error.stderr?.toString());}
 assert.ok(fs.existsSync(paths.journal));assert.ok(fs.existsSync(paths.lock));
 return {paths,options};
}
test('trusted renewal atomically publishes a pair and its owned DER pin without changing authorization',()=>{
 const f=fixture(),calls=[];
 const result=f.deploy({run:(binary,args)=>{calls.push([binary,args]);return openssl(args);}});
 assert.deepEqual(result,{server_cert_sha256:pin(renewed.chain)});
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),renewed.chain);
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'privkey.pem')),fs.readFileSync(renewed.key));
 assert.deepEqual(fs.readFileSync(f.paths.policy),f.old.policy);
 assert.deepEqual(JSON.parse(fs.readFileSync(join(f.paths.current,certificatePinFilename))),
  {version:1,hostname:originHostname,origin_sni:originSni,server_cert_sha256:pin(renewed.chain)});
 assert.equal(fs.existsSync(f.paths.ready),false);assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.lock),false);
 for(const path of [join(f.paths.current,'fullchain.pem'),join(f.paths.current,'privkey.pem'),join(f.paths.current,certificatePinFilename),f.paths.policy])assert.equal(fs.statSync(path).mode&0o777,0o600);
 assert.equal(calls.length,1);assert.equal(calls[0][0],'/usr/bin/openssl');
 for(const flag of ['-purpose','sslserver','-verify_hostname',originSni,'-no-CApath','-no-CAstore','-CAfile','-untrusted'])assert.ok(calls[0][1].includes(flag));
 assert.ok(!calls[0][1].includes(f.paths.sourceKey));assert.ok(!calls[0][1].some(value=>value.includes('BEGIN')||value.includes('fixture-sensitive')));
});
test('certificate deployment never writes authorization, including policy without a legacy server pin',()=>{
 const f=fixture(),policy={...f.policy};delete policy.server_cert_sha256;
 f.put(f.paths.policy,JSON.stringify(policy));const exact=fs.readFileSync(f.paths.policy);
 const filesystem={...fs,renameSync(from,to){
  assert.notEqual(to,f.paths.policy,'certificate hook tried to replace authorization');
  return fs.renameSync(from,to);
 }};
 f.deploy({fs:filesystem});assert.deepEqual(fs.readFileSync(f.paths.policy),exact);
 assert.equal(JSON.parse(fs.readFileSync(join(f.paths.current,certificatePinFilename))).server_cert_sha256,pin(renewed.chain));
});
test('first installation succeeds without an existing current pair; failed installation restores absence',()=>{
 const f=fixture();fs.rmSync(f.paths.current,{recursive:true});f.deploy();assert.ok(fs.existsSync(join(f.paths.current,'privkey.pem')));
 const scaffold=fixture();fs.rmSync(scaffold.paths.current,{recursive:true});fs.mkdirSync(scaffold.paths.current,{mode:0o700});
 scaffold.deploy();assert.ok(fs.existsSync(join(scaffold.paths.current,'fullchain.pem')));
 const g=fixture();fs.rmSync(g.paths.current,{recursive:true});
 assert.throws(()=>g.deploy({checkpoint:point=>{if(point==='pair')throw Error('private failure');}}),/^Error: CPE origin certificate deployment unavailable$/);
 assert.equal(fs.existsSync(g.paths.current),false);assert.deepEqual(fs.readFileSync(g.paths.policy),g.old.policy);assert.equal(fs.existsSync(g.paths.ready),false);
});
test('wrong SAN, CN-only names, wildcards, a mismatched key and an untrusted CA never deploy',()=>{
 for(const source of [wrong,cnOnly,wildcard,rogue]){
  const f=fixture();f.put(f.paths.sourceChain,source.chain);f.put(f.paths.sourceKey,fs.readFileSync(source.key));rejected(f);
 }
 const f=fixture();f.put(f.paths.sourceKey,fs.readFileSync(current.key));rejected(f);
});
test('future, expired and sub-72h certificates fail; exactly 72h remaining is accepted',()=>{
 const leaf=new X509Certificate(renewed.chain),start=Date.parse(leaf.validFrom),end=Date.parse(leaf.validTo);
 for(const at of [start-1,end+1,end-72*3600000+1]){const f=fixture();rejected(f,{now:()=>at});}
 const f=fixture();assert.equal(f.deploy({now:()=>end-72*3600000}).server_cert_sha256,pin(renewed.chain));
 for(const at of [Infinity,-1,NaN])rejected(fixture(),{now:()=>at});
});
test('root regular non-symlink inputs and root-controlled parents are required',()=>{
 for(const name of ['sourceChain','sourceKey','policy','manifest']){
  const f=fixture(),path=f.paths[name];fs.chmodSync(path,0o620);rejected(f);
 }
 for(const name of ['sourceChain','sourceKey','manifest']){
  const f=fixture(),path=f.paths[name],copy=path+'.real';fs.renameSync(path,copy);fs.symlinkSync(copy,path);rejected(f);
 }
 const f=fixture();fs.chmodSync(dirname(f.paths.sourceChain),0o720);rejected(f);fs.chmodSync(dirname(f.paths.sourceChain),0o700);
 const g=fixture();fs.chownSync(g.paths.sourceKey,65534,65534);rejected(g);fs.chownSync(g.paths.sourceKey,0,0);
 const h=fixture();fs.unlinkSync(h.paths.sourceKey);execFileSync('mkfifo',[h.paths.sourceKey]);rejected(h);
 const i=fixture();i.put(i.paths.sourceChain,'x'.repeat(131073));rejected(i);
});
test('manifest and enabled mTLS policy must be explicit; malformed source material remains private',()=>{
 for(const patch of [{enabled:false},{source_policy:'cidr'},{client_ca_sha256:'C'.repeat(64)},{server_cert_sha256:null},{hostname:'unmatched.invalid'}]){
  const f=fixture();f.put(f.paths.policy,JSON.stringify({...f.policy,...patch}));f.old.policy=fs.readFileSync(f.paths.policy);rejected(f);
 }
 for(const patch of [{version:2},{hostname:'unmatched.invalid'},{origin_sni:'unmatched.invalid'}]){
  const f=fixture();f.put(f.paths.manifest,JSON.stringify({version:1,hostname:originHostname,origin_sni:originSni,...patch}));rejected(f);
 }
 for(const source of ['private failure secret','-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----\n',renewed.chain+'secret']){
  const f=fixture();f.put(f.paths.sourceChain,source);rejected(f);
 }
 const f=fixture();rejected(f,{run:()=>{throw Error('fixture-sensitive-password-value');}});
});
test('failures after each transaction boundary restore the exact complete old pair and policy',()=>{
 for(const boundary of ['journal','old-pair-moved','pair','pin']){
  const f=fixture();let observed=false;
  rejected(f,{checkpoint:point=>{if(point===boundary){observed=true;assert.ok(fs.existsSync(f.paths.journal));assert.equal(fs.existsSync(f.paths.ready),false);throw Error('private rollback failure');}}});
  assert.equal(observed,true);assert.equal(fs.existsSync(f.paths.ready),false);assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.lock),false);
 }
});
test('an interrupted rollback leaves durable backups and a fail-closed journal, then recovers repeatably',()=>{
 const f=fixture();
 rejected(f,{checkpoint:point=>{if(point==='pair'||point==='rollback')throw Error('private interrupted failure');}});
 assert.ok(fs.existsSync(f.paths.journal));assert.equal(fs.existsSync(f.paths.ready),false);
 // A later invocation always recovers first, even if its new ACME input is bad.
 f.put(f.paths.sourceChain,'private invalid certificate');rejected(f);
 assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.ready),false);
});
test('same-process reentrancy and a live external lock cannot take over a transaction',()=>{
 const f=fixture();let nested=false;
 f.deploy({run:(bin,args)=>{
  assert.throws(()=>f.deploy(),/^Error: CPE origin certificate deployment unavailable$/);nested=true;return openssl(args);
 }});assert.equal(nested,true);
 const g=fixture();const owner=new OriginCertificateDeployer(g.options),release=owner.acquire();
 try{rejected(g);assert.ok(fs.existsSync(g.paths.lock));}finally{release();}
 assert.equal(fs.existsSync(g.paths.lock),false);
});
test('a stale lock is identified by Linux process starttime and recovered without signalling processes',()=>{
 const f=fixture();fs.mkdirSync(f.paths.lock,{mode:0o700});
 f.put(join(f.paths.lock,'a'.repeat(24),'owner.json'),JSON.stringify({pid:2147483647,start:'1',token:'a'.repeat(24),ticket:'1'}));
 f.deploy();assert.equal(fs.existsSync(f.paths.lock),false);
});
test('administrative disable and CA changes at every publication boundary survive rollback byte-for-byte',()=>{
 for(const boundary of ['journal','old-pair-moved','pair','pin']){
  const f=fixture(),changed=Buffer.from(JSON.stringify({...f.policy,enabled:false,client_ca_sha256:'d'.repeat(64)}));
  assert.throws(()=>f.deploy({checkpoint:point=>{if(point===boundary)f.put(f.paths.policy,changed);}}),/^Error: CPE origin certificate deployment unavailable$/);
  assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),f.old.chain);
  assert.deepEqual(fs.readFileSync(join(f.paths.current,'privkey.pem')),f.old.key);
  assert.deepEqual(fs.readFileSync(join(f.paths.current,certificatePinFilename)),f.old.certificatePin);
  assert.deepEqual(fs.readFileSync(f.paths.policy),changed);
  assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.ready),false);
  assert.throws(()=>f.deploy(),/^Error: CPE origin certificate deployment unavailable$/);
  assert.deepEqual(fs.readFileSync(f.paths.policy),changed);
 }
});
test('policy edits injected within recovery pair moves and fsync are never overwritten',()=>{
 for(const location of ['move','fsync']){
  const f=fixture(),changed=Buffer.from(JSON.stringify({...f.policy,enabled:false,client_ca_sha256:'e'.repeat(64),custom:{administrator:'preserved'}}));
  assert.throws(()=>f.deploy({checkpoint:point=>{if(point==='pair'||point==='rollback')throw Error('interrupted rollback');}}));
  assert.ok(fs.existsSync(f.paths.journal));
  let restored=false,injected=false;
  const filesystem={...fs,
   renameSync(from,to){fs.renameSync(from,to);if(to===f.paths.current&&from.startsWith(f.paths.journal+'/restore-')){
    restored=true;if(location==='move'){f.put(f.paths.policy,changed);injected=true;}
   }},
   fsyncSync(fd){if(restored&&location==='fsync'&&!injected){f.put(f.paths.policy,changed);injected=true;}return fs.fsyncSync(fd);}
  };
  const recovery=new OriginCertificateDeployer({...f.options,fs:filesystem});
  assert.equal(recovery.recover(),true);assert.equal(injected,true);
  assert.deepEqual(fs.readFileSync(f.paths.policy),changed);
  assert.deepEqual(fs.readFileSync(join(f.paths.current,certificatePinFilename)),f.old.certificatePin);
  assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.ready),false);
 }
});
test('authorization changes made by a filesystem writer inside certificate publication are preserved',()=>{
 const f=fixture(),changed=Buffer.from(JSON.stringify({...f.policy,enabled:false,client_ca_sha256:'f'.repeat(64)}));
 let injected=false;
 const filesystem={...fs,renameSync(from,to){
  fs.renameSync(from,to);
  if(!injected&&from===join(f.paths.journal,'next')&&to===f.paths.current){f.put(f.paths.policy,changed);injected=true;}
 }};
 assert.throws(()=>f.deploy({fs:filesystem}),/^Error: CPE origin certificate deployment unavailable$/);
 assert.equal(injected,true);assert.deepEqual(fs.readFileSync(f.paths.policy),changed);
 assert.deepEqual(fs.readFileSync(join(f.paths.current,certificatePinFilename)),f.old.certificatePin);
});
test('legacy current pair is bootstrapped with a pin; invalid or extraneous pin state is rejected',()=>{
 const f=fixture();fs.unlinkSync(join(f.paths.current,certificatePinFilename));f.old.certificatePin=null;
 f.deploy();assert.equal(JSON.parse(fs.readFileSync(join(f.paths.current,certificatePinFilename))).server_cert_sha256,pin(renewed.chain));
 for(const patch of [{version:2},{hostname:'unmatched.invalid'},{origin_sni:'unmatched.invalid'},
  {server_cert_sha256:pin(renewed.chain)},{server_cert_sha256:'A'.repeat(64)},{extra:'field'}]){
  const g=fixture();g.put(join(g.paths.current,certificatePinFilename),JSON.stringify({version:1,hostname:originHostname,origin_sni:originSni,server_cert_sha256:pin(current.chain),...patch}));
  g.old.certificatePin=fs.readFileSync(join(g.paths.current,certificatePinFilename));rejected(g);
 }
});
test('legacy policy journal recovery restores only certificate material and leaves current authorization exact',()=>{
 const f=fixture(),changed=Buffer.from(JSON.stringify({...f.policy,enabled:false,client_ca_sha256:'e'.repeat(64)}));
 const nextPolicy=Buffer.from(JSON.stringify({...f.policy,server_cert_sha256:pin(renewed.chain)}));
 f.put(join(f.paths.journal,'previous','fullchain.pem'),f.old.chain);
 f.put(join(f.paths.journal,'previous','privkey.pem'),f.old.key);
 f.put(join(f.paths.journal,'previous-policy.json'),f.old.policy);f.put(join(f.paths.journal,'next-policy.json'),nextPolicy);
 f.put(join(f.paths.journal,'transaction.json'),JSON.stringify({version:1,hadCurrent:true,policyHash:hash(f.old.policy),nextPolicyHash:hash(nextPolicy),
  nextChainHash:hash(renewed.chain),nextKeyHash:hash(fs.readFileSync(renewed.key)),oldChainHash:hash(f.old.chain),oldKeyHash:hash(f.old.key)}));
 f.put(f.paths.policy,changed);
 assert.equal(new OriginCertificateDeployer(f.options).recover(),true);
 assert.deepEqual(fs.readFileSync(f.paths.policy),changed);assert.equal(fs.existsSync(join(f.paths.current,certificatePinFilename)),false);
 assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.ready),false);
});
test('SIGKILL leaves a recoverable transaction and dead lease, and the next invocation restores old bytes',()=>{
 const f=fixture(),module=new URL('../Scripts/cpe5g-ipv6/deploy-origin-certificate.mjs',import.meta.url).href;
 const script=`import {OriginCertificateDeployer} from ${JSON.stringify(module)}; new OriginCertificateDeployer({...${JSON.stringify(f.options)},checkpoint:point=>{if(point==='pair')process.kill(process.pid,'SIGKILL');}}).deploy();`;
 try{execFileSync(process.execPath,['--input-type=module','-e',script],{stdio:['ignore','pipe','pipe']});assert.fail('child was not interrupted');}
 catch(error){assert.equal(error.signal,'SIGKILL');}
 assert.ok(fs.existsSync(f.paths.journal));assert.ok(fs.existsSync(f.paths.lock));assert.equal(fs.existsSync(f.paths.ready),false);
 f.put(f.paths.sourceChain,'invalid new ACME input');rejected(f);
 assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.lock),false);
});
test('an ACME callback preserves a SIGKILLed private restore until its owner recovers, then renewal resumes',()=>{
 const f=fixture(),restore=interruptedPrivateRestore(f);
 assert.equal(f.paths.restoreJournal,restore.paths.journal);
 const before=Object.fromEntries([f.paths.current,f.paths.policy,f.paths.manifest,restore.paths.journal].map(path=>[path,snapshot(path)]));
 let verified=false,stderr='';
 const deployer=new OriginCertificateDeployer({...f.options,run:()=>{verified=true;assert.fail('ACME verified material before private recovery');}});
 assert.equal(certificateMain({deployer,stderr:text=>stderr+=text}),1);
 assert.equal(stderr,'CPE origin certificate deployment unavailable\n');assert.equal(verified,false);
 for(const [path,value] of Object.entries(before))assert.deepEqual(snapshot(path),value);
 assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.lock),false);
 assert.equal(fs.existsSync(f.paths.ready),false);
 assert.deepEqual(new LuckyPrivateRestorer(restore.options).restore(),{status:'restored',restored:9});
 assert.equal(fs.existsSync(restore.paths.journal),false);
 const exactPolicy=fs.readFileSync(f.paths.policy);
 assert.deepEqual(f.deploy(),{server_cert_sha256:pin(renewed.chain)});
 assert.deepEqual(fs.readFileSync(f.paths.policy),exactPolicy);
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),renewed.chain);
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'privkey.pem')),fs.readFileSync(renewed.key));
 assert.equal(JSON.parse(fs.readFileSync(join(f.paths.current,certificatePinFilename))).server_cert_sha256,pin(renewed.chain));
});
test('a foreign restore journal gates certificate recovery before either transaction can be changed',()=>{
 const f=fixture(),module=new URL('../Scripts/cpe5g-ipv6/deploy-origin-certificate.mjs',import.meta.url).href;
 const script=`import {OriginCertificateDeployer} from ${JSON.stringify(module)}; new OriginCertificateDeployer({...${JSON.stringify(f.options)},checkpoint:point=>{if(point==='pair')process.kill(process.pid,'SIGKILL');}}).deploy();`;
 try{execFileSync(process.execPath,['--input-type=module','-e',script],{stdio:['ignore','pipe','pipe'],timeout:5000});assert.fail('certificate deploy was not interrupted');}
 catch(error){assert.equal(error.signal,'SIGKILL');}
 f.put(join(f.paths.restoreJournal,'owner-marker'),'foreign private restore transaction');
 const before=Object.fromEntries([f.paths.current,f.paths.policy,f.paths.journal,f.paths.restoreJournal].map(path=>[path,snapshot(path)]));
 assert.throws(()=>f.deploy(),/^Error: CPE origin certificate deployment unavailable$/);
 for(const [path,value] of Object.entries(before))assert.deepEqual(snapshot(path),value);
 assert.equal(fs.existsSync(f.paths.lock),false);assert.equal(fs.existsSync(f.paths.ready),false);
});
test('the foreign journal gate rejects any existing entry and an untrusted parent without following or deleting it',()=>{
 for(const kind of ['file','directory','symlink']){
  const f=fixture();
  if(kind==='file')f.put(f.paths.restoreJournal,'foreign transaction');
  else if(kind==='directory')f.put(join(f.paths.restoreJournal,'owner-marker'),'foreign transaction');
  else fs.symlinkSync(join(f.root,'absent-target'),f.paths.restoreJournal);
  const before=fs.lstatSync(f.paths.restoreJournal);rejected(f);
  const after=fs.lstatSync(f.paths.restoreJournal);assert.equal(after.ino,before.ino);assert.equal(after.mode,before.mode);
  assert.equal(fs.existsSync(f.paths.journal),false);
 }
 const f=fixture();fs.chmodSync(dirname(f.paths.restoreJournal),0o720);rejected(f);
 assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.ready),true);
});
test('standard OpenWrt /var alias and sticky /tmp runtime layout permit readiness removal',()=>{
 const f=fixture();f.paths.ready=join(fixtureRoot,'var/run/cpe5g-lucky/public-ready.json');
 const temporary=join(fixtureRoot,'tmp');fs.mkdirSync(temporary,{mode:0o1777});fs.chmodSync(temporary,0o1777);
 fs.symlinkSync(temporary,join(fixtureRoot,'var'));
 f.put(f.paths.ready,JSON.stringify({ready:true}));f.deploy();
 assert.equal(fs.existsSync(f.paths.ready),false);assert.equal(fs.existsSync(f.paths.journal),false);
});
test('a reordered or extraneous chain cannot deploy material the supervisor would reject',()=>{
 const f=fixture();f.put(f.paths.sourceChain,Buffer.concat([renewed.chain,fs.readFileSync(trusted.crt),fs.readFileSync(intermediate.crt)]));rejected(f);
 const g=fixture();g.put(g.paths.sourceChain,Buffer.concat([fs.readFileSync(renewed.crt),fs.readFileSync(trusted.crt),fs.readFileSync(intermediate.crt)]));rejected(g);
});
test('import is side-effect free, wrapper is executable, and CLI cannot redirect fixed trusted inputs',()=>{
 const module=new URL('../Scripts/cpe5g-ipv6/deploy-origin-certificate.mjs',import.meta.url);
 assert.equal(execFileSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(module.href)}); process.stdout.write('import-only');`],{encoding:'utf8'}),'import-only');
 const wrapper=fileURLToPath(new URL('../Scripts/cpe5g-ipv6/deploy-origin-certificate',import.meta.url));
 assert.match(fs.readFileSync(wrapper,'utf8'),/exec \/usr\/bin\/node \/usr\/libexec\/cpe5g-ipv6\/deploy-origin-certificate\.mjs/);
 assert.ok(fs.statSync(wrapper).mode&0o111);
 try{execFileSync(process.execPath,[fileURLToPath(module),'--ca-file',trusted.crt],{encoding:'utf8',stdio:['ignore','pipe','pipe'],env:{...process.env,CPE_ORIGIN_CA_FILE:trusted.crt}});assert.fail('CLI accepted override');}
 catch(error){assert.equal(error.status,1);assert.equal(error.stdout,'');assert.equal(error.stderr,'CPE origin certificate deployment unavailable\n');}
});
