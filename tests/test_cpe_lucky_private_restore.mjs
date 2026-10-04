import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync,spawnSync} from 'node:child_process';
import {createHash,X509Certificate} from 'node:crypto';
import {dirname,join} from 'node:path';
import {LuckyPrivateRestorer,privateRestorePaths,restoreLuckyPrivate,privateRestoreMain} from '../Scripts/cpe5g-ipv6/restore-lucky-private.mjs';
import {loadManagedSeed,managedPaths,reconcileLuckyManaged,managedMain} from '../Scripts/cpe5g-ipv6/reconcile-lucky-managed.mjs';
import {OriginCertificateDeployer,certificatePaths} from '../Scripts/cpe5g-ipv6/deploy-origin-certificate.mjs';
import {loadOrigin} from '../Scripts/cpe5g-ipv6/lucky-origin.mjs';

const root=fs.mkdtempSync('/tmp/cpe-private-restore-test-');
after(()=>fs.rmSync(root,{recursive:true,force:true}));
const openssl=args=>execFileSync('/usr/bin/openssl',args,{stdio:['ignore','pipe','pipe']});
const write=(path,bytes)=>{fs.mkdirSync(dirname(path),{recursive:true,mode:0o700});fs.writeFileSync(path,bytes,{mode:0o600});};
const digest=bytes=>createHash('sha256').update(new X509Certificate(bytes).raw).digest('hex');
function authority(name){
 const key=join(root,name+'.key'),cert=join(root,name+'.crt');
 openssl(['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes','-days','60',
  '-subj','/CN='+name,'-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign','-keyout',key,'-out',cert]);
 return {key,cert};
}
const trusted=authority('server-ca'),client=authority('client-ca'),rogue=authority('rogue-ca');
function issued(name,{issuer=trusted,san='cpe-origin.jmsu.top',purpose='serverAuth',days='30'}={}){
 const key=join(root,name+'.key'),csr=join(root,name+'.csr'),cert=join(root,name+'.crt'),ext=join(root,name+'.ext');
 openssl(['req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes','-subj','/CN='+name,'-keyout',key,'-out',csr]);
 write(ext,'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage='+purpose+'\nsubjectAltName=DNS:'+san+'\n');
 openssl(['x509','-req','-in',csr,'-CA',issuer.cert,'-CAkey',issuer.key,'-CAcreateserial','-days',days,'-extfile',ext,'-out',cert]);
 return {chain:fs.readFileSync(cert),key:fs.readFileSync(key)};
}
const initial=issued('initial'),renewed=issued('renewed',{days:'45'}),health=issued('health',{issuer:client,purpose:'clientAuth',days:'50'}),
 expiredHealth=issued('expired-health',{issuer:client,purpose:'clientAuth'}),
 wrong=issued('wrong',{san:'unmatched.invalid'}),untrusted=issued('untrusted',{issuer:rogue});
const pairNames=['certificate-pin.json','fullchain.pem','privkey.pem'];
function fixture(){
 const directory=fs.mkdtempSync(join(root,'case-'));
 const paths=Object.fromEntries(Object.entries(privateRestorePaths).map(([name,path])=>[name,directory+path]));
 const manifest={version:1,hostname:'cpe.lucky.jmsu.top',origin_sni:'cpe-origin.jmsu.top',lucky_rule_key:'rule-cpe-owned',
  ddns_task_key:'dns-cpe-owned',ssl_task_key:'ssl-cpe-owned',origin_header_secret:'a'.repeat(64),username:'cpe-temp',password:'FixturePrivateRestorePassword!'};
 const policy={enabled:true,hostname:manifest.hostname,source_policy:'mtls',client_ca_sha256:digest(fs.readFileSync(client.cert)),
  server_cert_sha256:digest(initial.chain),allowed_sources:[]};
 const managed={version:1,domain_suffix:'jmsu.top',
  rule:{RuleKey:manifest.lucky_rule_key,RuleName:'managed-cpe-udx-public-backend',Enable:true,Network:'tcp4',ListenIP:'127.0.0.1',ListenPort:16801,EnableTLS:false,Http3:false,
   DefaultProxy:{WebServiceType:'close',Locations:[]},ProxyList:[{Key:'child-cpe-owned',Enable:true,WebServiceType:'reverseproxy',
    Domains:[manifest.hostname],Locations:['http://192.168.66.1:6677'],EnableBasicAuth:true,WebAuth:true,
    BasicAuthUserList:manifest.username+':'+manifest.password,CacheEnabled:false,OtherParams:{WebAuth:true,BasicAuthRegConf:'',AutoOptionsFirewall:false}}]},
  ddns:{TaskKey:manifest.ddns_task_key,TaskName:'managed-cpe5g-origin-ipv6',Enable:true,TaskType:'IPv6',V4QueryIPEnable:false,V6QueryIPEnable:true,V6QueryIPType:'command',
   V6GetIPScript:'/usr/libexec/cpe5g-ipv6/select-origin-ipv6',DNS:{Name:'alidns',CallAPINetwork:'tcp4',ID:'fixture-dns-id',Secret:'fixture-dns-secret'},
   Records:[{SyncRecordData:{type:'AAAA',fullDomainName:manifest.origin_sni,ipv6Address:'{ipv6Addr}'}}]},
  ssl:{Key:manifest.ssl_task_key,Remark:'cpe5g-origin',Enable:true,AddFrom:'acme',MappingToPath:true,MappingPath:'/etc/lucky/cert-sync/cpe5g-acme',
   MappingChangeScript:'/usr/libexec/cpe5g-ipv6/deploy-origin-certificate',AllSyncClient:false,SyncClientList:[],
   ExtParams:{acmeDNSServer:'alidns',acmeDomains:[manifest.origin_sni],acmeDNSID:'fixture-dns-id',acmeDNSSecret:'fixture-dns-secret',
    acmeCADirURL:'https://acme-v02.api.letsencrypt.org/directory',acmeProxy:''}}};
 const pin=material=>({version:1,hostname:manifest.hostname,origin_sni:manifest.origin_sni,server_cert_sha256:digest(material.chain)});
 const romPath=path=>join(paths.rom,path.slice(directory.length));
 const seed={policy:JSON.stringify(policy),manifest:JSON.stringify(manifest),managed:JSON.stringify(managed),
  clientCa:fs.readFileSync(client.cert),healthCert:health.chain,healthKey:health.key};
 for(const [name,bytes] of Object.entries(seed))write(romPath(paths[name]),bytes);
 write(join(romPath(paths.current),'fullchain.pem'),initial.chain);write(join(romPath(paths.current),'privkey.pem'),initial.key);
 write(join(romPath(paths.current),'certificate-pin.json'),JSON.stringify(pin(initial)));
 write(directory+'/etc/lucky/cert-sync/lucky.token','existing-private-token');
 write(directory+'/etc/lucky/lucky_base.lkcf','existing-encrypted-native-configuration');
 const options={paths,rootBoundary:root,caFile:trusted.cert};
 return {directory,paths,manifest,policy,managed,seed,romPath,pin,options,
  put(name,bytes){write(paths[name],typeof bytes==='object'&&!Buffer.isBuffer(bytes)?JSON.stringify(bytes):bytes);},
  pair(material=initial){write(join(paths.current,'fullchain.pem'),material.chain);write(join(paths.current,'privkey.pem'),material.key);write(join(paths.current,'certificate-pin.json'),JSON.stringify(pin(material)));},
  restore(extra={}){return restoreLuckyPrivate({...options,...extra});}};
}
function nativeUntouched(f){
 assert.equal(fs.readFileSync(f.directory+'/etc/lucky/cert-sync/lucky.token','utf8'),'existing-private-token');
 assert.equal(fs.readFileSync(f.directory+'/etc/lucky/lucky_base.lkcf','utf8'),'existing-encrypted-native-configuration');
}
function missing(f){
 for(const name of ['policy','manifest','managed','clientCa','healthCert','healthKey'])assert.equal(fs.existsSync(f.paths[name]),false,name);
 assert.equal(fs.existsSync(f.paths.current),false);
}
test('missing legacy private files restore from coherent ROM, with authorization published last',()=>{
 const f=fixture(),steps=[];
 assert.deepEqual(f.restore({checkpoint:step=>{
  steps.push(step);
  if(step!=='policy')assert.equal(fs.existsSync(f.paths.policy),false,'authorization appeared before complete private material');
 }}),{status:'restored',restored:9});
 assert.equal(steps.at(-1),'policy');nativeUntouched(f);
 for(const name of ['policy','manifest','managed','clientCa','healthCert','healthKey']){
  assert.deepEqual(fs.readFileSync(f.paths[name]),Buffer.from(f.seed[name]));assert.equal(fs.statSync(f.paths[name]).mode&0o777,0o600);
 }
 assert.equal(fs.statSync(f.paths.current).mode&0o777,0o700);
 for(const name of pairNames)assert.equal(fs.statSync(join(f.paths.current,name)).mode&0o777,0o600);
 assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.lock),false);
 assert.deepEqual(f.restore(),{status:'unchanged',restored:0});
});
test('complete valid renewed certificate pair and owned pin survive an older ROM generation exactly',()=>{
 const f=fixture();for(const [name,bytes] of Object.entries(f.seed))f.put(name,bytes);f.pair(renewed);
 const before=Object.fromEntries(pairNames.map(name=>[name,{bytes:fs.readFileSync(join(f.paths.current,name)),ino:fs.statSync(join(f.paths.current,name)).ino}]));
 assert.deepEqual(f.restore(),{status:'unchanged',restored:0});
 for(const name of pairNames){assert.deepEqual(fs.readFileSync(join(f.paths.current,name)),before[name].bytes);assert.equal(fs.statSync(join(f.paths.current,name)).ino,before[name].ino);}
 assert.equal(JSON.parse(fs.readFileSync(f.paths.policy)).server_cert_sha256,digest(initial.chain));nativeUntouched(f);
});
test('an expired unused ROM pair cannot stop a retained currently valid renewed pair',()=>{
 const f=fixture();for(const [name,bytes] of Object.entries(f.seed))f.put(name,bytes);f.pair(renewed);
 assert.deepEqual(f.restore({now:()=>Date.now()+31*86400000}),{status:'unchanged',restored:0});
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),renewed.chain);
 const g=fixture();assert.deepEqual(g.restore({now:()=>Date.now()+31*86400000}),{status:'restored',restored:6,pendingCertificate:true});
 assert.equal(fs.existsSync(g.paths.current),false);assert.ok(fs.existsSync(g.paths.managed));
});
test('expired ROM pair permits native ACME boot progress but origin stays closed until trusted deployment',async()=>{
 const f=fixture(),future=Date.now()+31*86400000;
 // Simulate an old retained native configuration with no CPE ACME job.
 write(f.directory+'/etc/lucky/lucky_ssl.lkcf','retained-old-native-config-without-cpe-acme-job');
 const restorer=new LuckyPrivateRestorer({...f.options,now:()=>future});
 assert.equal(privateRestoreMain({restorer}),0);assert.equal(fs.existsSync(f.paths.current),false);
 const mappedFs={...fs,
  openSync:(path,...args)=>fs.openSync(typeof path==='string'&&path.startsWith('/')?f.directory+path:path,...args),
  lstatSync:(path,...args)=>fs.lstatSync(typeof path==='string'&&path.startsWith('/')?f.directory+path:path,...args)};
 assert.throws(()=>loadOrigin({fs:mappedFs,now:()=>future}),/^Error: CPE public origin unavailable$/);
 const paths=Object.fromEntries(Object.entries(managedPaths).map(([name,path])=>[name,f.directory+path]));
 const load=()=>loadManagedSeed({paths,rootBoundary:root}),stored={rule:[],ddns:[],ssl:[]},posted=[],keys={};
 const api=async(method,path,body)=>{
  if(path==='/api/ddns/configure')return {ret:0,ddnsconfigure:{Enable:true,CustomDomainSuffix:'jmsu.top\n'}};
  const kind=path.startsWith('/api/webservice/')?'rule':path.startsWith('/api/ddns')?'ddns':'ssl',field=kind==='rule'?'RuleKey':kind==='ddns'?'TaskKey':'Key';
  if(method==='POST'){
   const value=structuredClone(body);value[field]='native-generated-'+kind;
   if(kind==='rule')value.ProxyList[0].Key='native-generated-child';
   stored[kind].push(value);posted.push({kind,body});return {ret:0,[field]:value[field]};
  }
  if(path.startsWith('/api/ddns/task/'))return {ret:0,task:structuredClone(stored.ddns[0])};
  if(path.startsWith('/api/ssl/'))return {ret:0,info:structuredClone(stored.ssl[0])};
  return {ret:0,[kind==='rule'?'ruleList':kind==='ddns'?'data':'list']:structuredClone(stored[kind])};
 };
 const registry={acquire:()=>()=>{},read:()=>null,write(value,check){check();Object.assign(keys,value);}};
 assert.equal(await managedMain({reconcile:()=>reconcileLuckyManaged({load,gate:()=>true,api,registry})}),0);
 assert.deepEqual(posted.map(value=>value.kind),['rule','ddns','ssl']);
 const job=posted.find(value=>value.kind==='ssl').body;
 assert.equal(job.CertBase64,'');assert.equal(job.KeyBase64,'');assert.equal(job.IssuerCertificate,'');
 assert.equal(job.MappingChangeScript,'/usr/libexec/cpe5g-ipv6/deploy-origin-certificate');assert.equal(keys.ssl_task_key,'native-generated-ssl');
 assert.equal(fs.readFileSync(f.directory+'/etc/lucky/lucky_ssl.lkcf','utf8'),'retained-old-native-config-without-cpe-acme-job');
 assert.throws(()=>loadOrigin({fs:mappedFs,now:()=>future}),/^Error: CPE public origin unavailable$/);
 const deployPaths=Object.fromEntries(Object.entries(certificatePaths).map(([name,path])=>[name,f.directory+path]));
 write(deployPaths.sourceChain,renewed.chain);write(deployPaths.sourceKey,renewed.key);
 new OriginCertificateDeployer({paths:deployPaths,rootBoundary:root,caFile:trusted.cert,now:()=>future}).deploy();
 assert.equal(loadOrigin({fs:mappedFs,now:()=>future}).pins.server_cert_sha256,digest(renewed.chain));nativeUntouched(f);
});
test('expired retained server pair is preserved while readiness is withdrawn and renewal can continue',()=>{
 const f=fixture();for(const [name,bytes] of Object.entries(f.seed))f.put(name,bytes);f.pair(initial);
 write(f.paths.ready,JSON.stringify({ready:true,updated:Date.now()}));
 const before=Object.fromEntries(pairNames.map(name=>[name,{bytes:fs.readFileSync(join(f.paths.current,name)),ino:fs.statSync(join(f.paths.current,name)).ino}]));
 assert.deepEqual(f.restore({now:()=>Date.now()+31*86400000}),{status:'unchanged',restored:0,pendingCertificate:true});
 assert.equal(fs.existsSync(f.paths.ready),false);
 for(const name of pairNames){assert.deepEqual(fs.readFileSync(join(f.paths.current,name)),before[name].bytes);assert.equal(fs.statSync(join(f.paths.current,name)).ino,before[name].ino);}
});
test('a server inside the 72-hour availability gate awaits renewal instead of blocking the ACME boot step',()=>{
 const f=fixture(),future=Date.now()+28*86400000,remaining=Date.parse(new X509Certificate(initial.chain).validTo)-future;
 assert.ok(remaining>0&&remaining<72*3600000);
 assert.deepEqual(f.restore({now:()=>future}),{status:'restored',restored:6,pendingCertificate:true});
 assert.equal(fs.existsSync(f.paths.current),false);assert.ok(fs.existsSync(f.paths.managed));nativeUntouched(f);
});
test('pending renewal never swallows wrong server SAN, key, pin, trust or expired client material',()=>{
 const future=Date.now()+31*86400000;
 for(const kind of ['san','key','pin','trust','health-expired','health-key','future-server']){
  const f=fixture();
  if(['san','key','pin','trust','future-server'].includes(kind)){
   f.pair(kind==='san'?wrong:kind==='trust'?untrusted:initial);
   if(kind==='key')write(join(f.paths.current,'privkey.pem'),renewed.key);
   if(kind==='pin')write(join(f.paths.current,'certificate-pin.json'),JSON.stringify({...f.pin(initial),server_cert_sha256:'b'.repeat(64)}));
  }
  if(kind==='health-expired'){f.put('healthCert',expiredHealth.chain);f.put('healthKey',expiredHealth.key);}
  if(kind==='health-key')f.put('healthKey',renewed.key);
  assert.throws(()=>f.restore({now:()=>kind==='future-server'?Date.now()-86400000:future}),/^Error: CPE private Lucky restoration unavailable$/);
  assert.equal(fs.existsSync(f.paths.policy),false);assert.equal(fs.existsSync(f.paths.managed),false);nativeUntouched(f);
 }
});
test('an exact disabled administrator policy remains untouched even with broken private ROM material',()=>{
 const f=fixture(),policy=JSON.stringify({hostname:f.manifest.hostname,enabled:false,reason:'administrator decision'},null,2)+'\n';
 f.put('policy',policy);fs.unlinkSync(f.romPath(f.paths.healthKey));
 assert.deepEqual(f.restore(),{status:'disabled',restored:0});assert.equal(fs.readFileSync(f.paths.policy,'utf8'),policy);
 assert.equal(fs.existsSync(f.paths.manifest),false);assert.equal(fs.existsSync(f.paths.journal),false);nativeUntouched(f);
});
test('an old generic disabled policy stays exact while missing private files are filled',()=>{
 const f=fixture();f.put('policy','{ "enabled": false }\n');const before=fs.readFileSync(f.paths.policy);
 assert.deepEqual(f.restore(),{status:'disabled-default',restored:8});assert.deepEqual(fs.readFileSync(f.paths.policy),before);
 assert.ok(fs.existsSync(f.paths.managed));assert.ok(fs.existsSync(join(f.paths.current,'certificate-pin.json')));
 assert.deepEqual(f.restore(),{status:'disabled-default',restored:0});nativeUntouched(f);
});
test('mismatched existing manifest, private DNS credentials or policy are never mixed with ROM',()=>{
 for(const kind of ['manifest','dns','policy']){
  const f=fixture();
  if(kind==='manifest')f.put('manifest',{...f.manifest,origin_header_secret:'b'.repeat(64)});
  if(kind==='dns'){const managed=structuredClone(f.managed);managed.ddns.DNS.Secret='different-dns-secret';managed.ssl.ExtParams.acmeDNSSecret='different-dns-secret';f.put('managed',managed);}
  if(kind==='policy')f.put('policy',{...f.policy,client_ca_sha256:'b'.repeat(64)});
  assert.throws(()=>f.restore(),/^Error: CPE private Lucky restoration unavailable$/);
  assert.equal(fs.existsSync(f.paths.current),false);assert.equal(fs.existsSync(f.paths.healthKey),false);nativeUntouched(f);
 }
});
test('a partial certificate directory restores all three coherent ROM files without mixing old pieces',()=>{
 const f=fixture();write(join(f.paths.current,'fullchain.pem'),renewed.chain);
 assert.deepEqual(f.restore(),{status:'restored',restored:9});
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),initial.chain);
 assert.deepEqual(fs.readFileSync(join(f.paths.current,'privkey.pem')),initial.key);
 assert.equal(JSON.parse(fs.readFileSync(join(f.paths.current,'certificate-pin.json'))).server_cert_sha256,digest(initial.chain));
});
test('complete malformed, wrong-SAN or untrusted kept pairs fail closed instead of being overwritten',()=>{
 for(const material of [wrong,untrusted,{chain:initial.chain,key:renewed.key}]){
  const f=fixture();f.pair(material);const before=fs.readFileSync(join(f.paths.current,'fullchain.pem'));
  assert.throws(()=>f.restore(),/^Error: CPE private Lucky restoration unavailable$/);
  assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),before);assert.equal(fs.existsSync(f.paths.policy),false);
 }
});
test('ROM server SAN, private key, DER pin and system trust are validated before restoration',()=>{
 for(const kind of ['san','key','pin','trust']){
  const f=fixture(),pair=f.romPath(f.paths.current);
  if(kind==='san'){write(join(pair,'fullchain.pem'),wrong.chain);write(join(pair,'privkey.pem'),wrong.key);write(join(pair,'certificate-pin.json'),JSON.stringify(f.pin(wrong)));}
  if(kind==='key')write(join(pair,'privkey.pem'),renewed.key);
  if(kind==='pin')write(join(pair,'certificate-pin.json'),JSON.stringify({...f.pin(initial),server_cert_sha256:'b'.repeat(64)}));
  if(kind==='trust'){write(join(pair,'fullchain.pem'),untrusted.chain);write(join(pair,'privkey.pem'),untrusted.key);write(join(pair,'certificate-pin.json'),JSON.stringify(f.pin(untrusted)));}
  assert.throws(()=>f.restore(),/^Error: CPE private Lucky restoration unavailable$/);missing(f);nativeUntouched(f);
 }
});
test('unsafe inputs and parent directories are refused before any private restoration',()=>{
 for(const kind of ['symlink','writable','parent-link','parent-writable','owner','fifo','oversized']){
  const f=fixture(),target=f.romPath(f.paths.healthKey);
  if(kind==='symlink'){fs.renameSync(target,target+'.real');fs.symlinkSync(target+'.real',target);}
  if(kind==='writable')fs.chmodSync(target,0o620);
  if(kind==='parent-link'){fs.renameSync(dirname(target),dirname(target)+'.real');fs.symlinkSync(dirname(target)+'.real',dirname(target));}
  if(kind==='parent-writable')fs.chmodSync(dirname(target),0o720);
  if(kind==='owner')fs.chownSync(target,65534,65534);
  if(kind==='fifo'){fs.unlinkSync(target);execFileSync('mkfifo',[target]);}
  if(kind==='oversized')write(target,'x'.repeat(65537));
  assert.throws(()=>f.restore(),/^Error: CPE private Lucky restoration unavailable$/);missing(f);nativeUntouched(f);
 }
 const f=fixture();fs.mkdirSync(dirname(f.paths.manifest),{recursive:true});fs.symlinkSync(f.romPath(f.paths.manifest),f.paths.manifest);
 assert.throws(()=>f.restore(),/^Error: CPE private Lucky restoration unavailable$/);assert.equal(fs.existsSync(f.paths.policy),false);
});
test('ordinary firmware without any private ROM seed is a side-effect-free skip; partial seed is refused',()=>{
 const f=fixture();fs.rmSync(f.paths.rom,{recursive:true});write(f.romPath(f.paths.policy),'{"enabled":false}\n');
 assert.deepEqual(f.restore(),{status:'no-private-seed',restored:0});missing(f);assert.equal(fs.existsSync(dirname(f.paths.journal)),false);
 const g=fixture();fs.unlinkSync(g.romPath(g.paths.managed));assert.throws(()=>g.restore(),/^Error: CPE private Lucky restoration unavailable$/);missing(g);
});
test('a concurrent administrator policy wins over exclusive authorization publication',()=>{
 const f=fixture(),admin='{ "enabled": false, "hostname": "cpe.lucky.jmsu.top" }\n';
 assert.throws(()=>f.restore({checkpoint:step=>{if(step==='pair')f.put('policy',admin);}}),/^Error: CPE private Lucky restoration unavailable$/);
 assert.equal(fs.readFileSync(f.paths.policy,'utf8'),admin);assert.equal(fs.existsSync(f.paths.manifest),false);
 assert.equal(fs.existsSync(f.paths.current),false);assert.equal(fs.existsSync(f.paths.journal),false);nativeUntouched(f);
});
test('failures at each restoration boundary roll back only files installed by the transaction',()=>{
 for(const boundary of ['journal','file:manifest','file:managed','file:healthKey','old-pair-moved','pair','policy']){
  const f=fixture();assert.throws(()=>f.restore({checkpoint:step=>{if(step===boundary)throw Error('fixture-private-failure');}}),/^Error: CPE private Lucky restoration unavailable$/);
  missing(f);assert.equal(fs.existsSync(f.paths.journal),false);nativeUntouched(f);
 }
 const g=fixture();write(join(g.paths.current,'fullchain.pem'),renewed.chain);
 assert.throws(()=>g.restore({checkpoint:step=>{if(step==='pair')throw Error('failure');}}),/^Error: CPE private Lucky restoration unavailable$/);
 assert.deepEqual(fs.readFileSync(join(g.paths.current,'fullchain.pem')),renewed.chain);
 assert.deepEqual(fs.readdirSync(g.paths.current),['fullchain.pem']);assert.equal(fs.existsSync(g.paths.policy),false);
});
test('failed rollback retains a durable journal gate and never publishes authorization',()=>{
 const f=fixture();assert.throws(()=>f.restore({checkpoint:step=>{if(step==='pair'||step==='rollback')throw Error('fixture-private-failure');}}),/^Error: CPE private Lucky restoration unavailable$/);
 assert.ok(fs.existsSync(f.paths.journal));assert.ok(fs.existsSync(join(f.paths.journal,'restore-transaction.json')));
 assert.equal(fs.existsSync(f.paths.policy),false);assert.deepEqual(f.restore(),{status:'restored',restored:9});
 assert.equal(fs.existsSync(f.paths.journal),false);nativeUntouched(f);
});
test('exclusive file and authorization publication failures are recorded before unlink or fsync can fail',()=>{
 for(const kind of ['manifest-unlink','policy-unlink','manifest-fsync','policy-fsync']){
  const f=fixture();let linked=false,failed=false;
  const target=kind.startsWith('policy')?f.paths.policy:f.paths.manifest;
  const filesystem={...fs,
   linkSync(source,destination){const result=fs.linkSync(source,destination);if(destination===target)linked=true;return result;},
   unlinkSync(path){
    if(linked&&!failed&&kind.endsWith('unlink')&&path===join(f.paths.journal,kind.startsWith('policy')?'policy':'manifest')){
     failed=true;throw Error('fixture-private-unlink-failure');
    }
    return fs.unlinkSync(path);
   },
   fsyncSync(fd){if(linked&&!failed&&kind.endsWith('fsync')){failed=true;throw Error('fixture-private-sync-failure');}return fs.fsyncSync(fd);}
  };
  assert.throws(()=>f.restore({fs:filesystem}),/^Error: CPE private Lucky restoration unavailable$/);
  assert.equal(linked,true);assert.equal(failed,true);missing(f);assert.equal(fs.existsSync(f.paths.journal),false);nativeUntouched(f);
 }
});
test('a concurrent administrator edit to an existing policy is preserved through private-file rollback',()=>{
 const f=fixture();f.put('policy',f.policy);const admin=JSON.stringify({...f.policy,enabled:false,reason:'concurrent edit'})+'\n';
 assert.throws(()=>f.restore({checkpoint:step=>{if(step==='pair')f.put('policy',admin);}}),/^Error: CPE private Lucky restoration unavailable$/);
 assert.equal(fs.readFileSync(f.paths.policy,'utf8'),admin);assert.equal(fs.existsSync(f.paths.manifest),false);
 assert.equal(fs.existsSync(f.paths.current),false);assert.equal(fs.existsSync(f.paths.journal),false);nativeUntouched(f);
});
function killedRestore(f,boundary){
 const module=new URL('../Scripts/cpe5g-ipv6/restore-lucky-private.mjs',import.meta.url).href;
 const source=`import {restoreLuckyPrivate} from ${JSON.stringify(module)};restoreLuckyPrivate({...${JSON.stringify(f.options)},checkpoint:step=>{if(step===${JSON.stringify(boundary)})process.kill(process.pid,'SIGKILL');}});`;
 const result=spawnSync(process.execPath,['--input-type=module','-e',source],{encoding:'utf8',timeout:5000});
 assert.equal(result.signal,'SIGKILL',result.stderr);assert.equal(result.status,null);assert.equal(result.stdout,'');
}
test('real SIGKILL at each publication boundary recovers automatically on the next boot',()=>{
 for(const boundary of ['journal','file:manifest','old-pair-moved','pair','policy']){
  const f=fixture();write(join(f.paths.current,'fullchain.pem'),renewed.chain);
  killedRestore(f,boundary);assert.ok(fs.existsSync(f.paths.journal));assert.ok(fs.existsSync(f.paths.lock));
  assert.deepEqual(f.restore(),{status:'restored',restored:9});
  assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),initial.chain);
  assert.deepEqual(fs.readFileSync(join(f.paths.current,'privkey.pem')),initial.key);
  assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.lock),false);nativeUntouched(f);
 }
});
test('recovery after a killed policy publication preserves an in-place administrator disable',()=>{
 const f=fixture();write(join(f.paths.current,'fullchain.pem'),renewed.chain);killedRestore(f,'policy');
 const admin=JSON.stringify({...f.policy,enabled:false,reason:'disable after interrupted upgrade'})+'\n';f.put('policy',admin);
 assert.deepEqual(f.restore(),{status:'disabled',restored:0});
 assert.equal(fs.readFileSync(f.paths.policy,'utf8'),admin);
 assert.deepEqual(fs.readdirSync(f.paths.current),['fullchain.pem']);assert.deepEqual(fs.readFileSync(join(f.paths.current,'fullchain.pem')),renewed.chain);
 assert.equal(fs.existsSync(f.paths.manifest),false);assert.equal(fs.existsSync(f.paths.journal),false);nativeUntouched(f);
});
test('recovery itself can be killed between pair moves and replayed safely',()=>{
 const f=fixture();write(join(f.paths.current,'fullchain.pem'),renewed.chain);killedRestore(f,'policy');
 killedRestore(f,'recovery-pair-removed');assert.ok(fs.existsSync(join(f.paths.journal,'discard-pair')));
 assert.equal(fs.existsSync(f.paths.current),false);
 assert.deepEqual(f.restore(),{status:'restored',restored:9});
 assert.equal(fs.existsSync(f.paths.journal),false);assert.equal(fs.existsSync(f.paths.lock),false);nativeUntouched(f);
});
test('tampered recovery metadata or changed private files keep the journal gate closed',()=>{
 for(const kind of ['path','inode','private-file']){
  const f=fixture();killedRestore(f,'pair');
  const recordPath=join(f.paths.journal,'restore-transaction.json'),record=JSON.parse(fs.readFileSync(recordPath));
  if(kind==='path'){record.files['../policy']=record.files.manifest;write(recordPath,JSON.stringify(record));}
  if(kind==='inode'){record.next_pair.ino++;write(recordPath,JSON.stringify(record));}
  if(kind==='private-file')f.put('manifest',{...f.manifest,origin_header_secret:'b'.repeat(64)});
  assert.throws(()=>f.restore(),/^Error: CPE private Lucky restoration unavailable$/);
  assert.ok(fs.existsSync(f.paths.journal));assert.equal(fs.existsSync(f.paths.policy),false);nativeUntouched(f);
 }
});
test('a pending certificate deployment blocks restoration without consuming its foreign journal',()=>{
 const f=fixture();fs.mkdirSync(f.paths.deployJournal,{recursive:true,mode:0o700});write(join(f.paths.deployJournal,'marker'),'certificate transaction');
 assert.throws(()=>f.restore(),/^Error: CPE private Lucky restoration unavailable$/);missing(f);
 assert.equal(fs.readFileSync(join(f.paths.deployJournal,'marker'),'utf8'),'certificate transaction');assert.equal(fs.existsSync(f.paths.journal),false);
});
test('valid owned native key remaps are retained while ROM secret identity remains authoritative',()=>{
 const f=fixture(),manifest={...f.manifest,lucky_rule_key:'live-rule-remap',ddns_task_key:'live-dns-remap',ssl_task_key:'live-ssl-remap'};
 const managed=structuredClone(f.managed);managed.rule.RuleKey='old-rule-reference';managed.ddns.TaskKey='old-dns-reference';managed.ssl.Key='old-ssl-reference';
 f.put('manifest',manifest);f.put('managed',managed);
 assert.equal(f.restore().status,'restored');assert.deepEqual(JSON.parse(fs.readFileSync(f.paths.manifest)),manifest);
 assert.deepEqual(JSON.parse(fs.readFileSync(f.paths.managed)),managed);nativeUntouched(f);
});
test('restoration emits only a generic error and importing the module has no filesystem side effects',()=>{
 const f=fixture();fs.unlinkSync(f.romPath(f.paths.healthKey));let stderr='';
 assert.equal(privateRestoreMain({restorer:new LuckyPrivateRestorer(f.options),stderr:text=>stderr+=text}),1);
 assert.equal(stderr,'CPE private Lucky restoration unavailable\n');assert.ok(!stderr.includes(f.manifest.password));
 const module=new URL('../Scripts/cpe5g-ipv6/restore-lucky-private.mjs',import.meta.url).href;
 const child=spawnSync(process.execPath,['--input-type=module','-e',`import fs from 'node:fs';for(const name of ['mkdirSync','writeFileSync','renameSync','unlinkSync','linkSync'])fs[name]=()=>{throw Error('import mutated filesystem');};await import(${JSON.stringify(module)});`],{encoding:'utf8'});
 assert.equal(child.status,0,child.stderr);assert.equal(child.stdout,'');nativeUntouched(f);
});
