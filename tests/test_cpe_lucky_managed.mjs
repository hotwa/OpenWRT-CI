import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {dirname,join} from 'node:path';
import {test,after} from 'node:test';
import {managedPaths,managedHostname,managedOrigin,validateManagedSeed,loadManagedSeed,restoreTerminal,
 readManagedFile,luckyApi,reconcileLuckyManaged,reconcileLuckyApi,managedMain,ManagedRegistry,validateManagedKeys} from '../Scripts/cpe5g-ipv6/reconcile-lucky-managed.mjs';
import {defaultApiService,apiRuleFromTemplate,apiRuleName,validateApiRule,apiBackendReady} from '../Scripts/cpe5g-ipv6/api-service-registry.mjs';
const root=fs.mkdtempSync('/tmp/cpe-lucky-managed-test-');
after(()=>fs.rmSync(root,{recursive:true,force:true}));
const clone=value=>JSON.parse(JSON.stringify(value));
const password='FixtureOnlyRandomLikePasswordValue123';
function material(){
 const manifest={version:1,hostname:managedHostname,origin_sni:managedOrigin,lucky_rule_key:'ownedRule',
  ddns_task_key:'ownedDdns',ssl_task_key:'ownedSsl',origin_header_secret:'a'.repeat(64),username:'cpe-temp',password};
 const seed={version:1,domain_suffix:'jmsu.top',
  rule:{RuleKey:manifest.lucky_rule_key,RuleName:'managed-cpe-udx-public-backend',Enable:true,Network:'tcp4',
   ListenIP:'127.0.0.1',ListenPort:16801,EnableTLS:false,Http3:false,DefaultProxy:{WebServiceType:'close',Locations:[]},
   ProxyList:[{Key:'ownedChild',Enable:true,WebServiceType:'reverseproxy',Domains:[managedHostname],
    Locations:['http://192.168.66.1:6677'],EnableBasicAuth:true,WebAuth:true,BasicAuthUserList:'cpe-temp:'+password,
    CacheEnabled:false,OtherParams:{WebAuth:true,BasicAuthRegConf:'',AutoOptionsFirewall:false,HttpClientProxyType:'',HttpClientProxyAddr:''}}]},
  ddns:{TaskKey:manifest.ddns_task_key,TaskName:'managed-cpe5g-origin-ipv6',TaskType:'IPv6',Enable:true,
   V4QueryIPEnable:false,V6QueryIPEnable:true,V6QueryIPType:'command',V6GetIPScript:'/usr/libexec/cpe5g-ipv6/select-origin-ipv6',
   DNS:{Name:'alidns',ID:'FixtureDedicatedDNSID',Secret:'FixtureDedicatedDNSSecret',CallAPINetwork:'tcp4',HttpClientProxyType:''},
   Records:[{Disable:false,SyncRecordData:{type:'AAAA',fullDomainName:managedOrigin,ipv6Address:'{ipv6Addr}'}}],
   WebhookEnable:false,GlobalWebhook:false},
  ssl:{Key:manifest.ssl_task_key,Remark:'cpe5g-origin',Enable:true,AddFrom:'acme',MappingToPath:true,
   MappingPath:'/etc/lucky/cert-sync/cpe5g-acme',MappingChangeScript:'/usr/libexec/cpe5g-ipv6/deploy-origin-certificate',
   AllSyncClient:false,SyncClientList:[],ExtParams:{acmeDNSServer:'alidns',acmeDomains:[managedOrigin],
    acmeDNSID:'FixtureDedicatedDNSID',acmeDNSSecret:'FixtureDedicatedDNSSecret',acmeCADirURL:'https://acme-v02.api.letsencrypt.org/directory',acmeProxy:''}}
 };
 return {seed,manifest,policy:{enabled:true,hostname:managedHostname,source_policy:'mtls',client_ca_sha256:'c'.repeat(64),allowed_sources:[]}};
}
function disk(){
 const dir=fs.mkdtempSync(join(root,'case-'));const paths=Object.fromEntries(Object.entries(managedPaths).map(([k,v])=>[k,dir+v]));
 const put=(file,value)=>{fs.mkdirSync(dirname(file),{recursive:true,mode:0o700});fs.writeFileSync(file,typeof value==='string'?value:JSON.stringify(value),{mode:0o600});};
 const data=material();put(paths.seed,data.seed);put(paths.manifest,data.manifest);put(paths.policy,data.policy);put(paths.token,'FixtureOpenTokenOnly');
 return {dir,paths,put,data,load:()=>loadManagedSeed({paths,rootBoundary:root})};
}
function native({owned=false}={}){
 const data=material(),calls=[];let counter=0;
 const config={Enable:true,CustomDomainSuffix:'example.test\njmsu.top\nother.test',WebhookProxyPassword:'PreservedUnrelatedSecret'};
 const registry={value:null,locked:false,acquire(){assert.equal(this.locked,false);this.locked=true;return()=>{this.locked=false;};},read(){return this.value;},write(value,check){check();this.value=clone(value);}};
 const state={rule:[{RuleKey:'userRule',Enable:false,userField:'keep exact',ProxyList:[]}],
  ddns:[{TaskKey:'userDdns',Enable:true,custom:{untouched:true}}],ssl:[{Key:'userSsl',Enable:true,userField:'keep exact'}]};
 if(owned)for(const kind of ['rule','ddns','ssl'])state[kind].push(clone(data.seed[kind]));
 const api=async(method,path,body)=>{
  calls.push({method,path,body:body&&clone(body)});
  if(method==='GET'){
   if(path==='/api/webservice/rules')return {ret:0,ruleList:clone(state.rule)};
   if(path==='/api/ddnstasklist')return {ret:0,data:clone(state.ddns)};
   if(path==='/api/ssl')return {ret:0,list:clone(state.ssl)};
   if(path==='/api/ddns/configure')return {ret:0,ddnsconfigure:clone(config)};
   if(path.startsWith('/api/ddns/task/'))return {ret:0,task:clone(state.ddns.find(x=>x.TaskKey===path.split('/').at(-1))??null)};
   if(path.startsWith('/api/ssl/'))return {ret:0,info:clone(state.ssl.find(x=>x.Key===path.split('/').at(-1))??null)};
  }
  if(method==='POST'){
   const kind=path==='/api/webservice/rules'?'rule':path==='/api/ddns'?'ddns':path==='/api/ssl'?'ssl':null;
   assert.ok(kind,'unexpected API mutation');const key=kind==='rule'?'RuleKey':kind==='ddns'?'TaskKey':'Key';
   const stored=clone(body);stored[key]='generated'+kind+(++counter);
   if(kind==='rule')for(const child of stored.ProxyList)child.Key='generatedChild'+counter;
   state[kind].push(stored);return {ret:0,[key]:stored[key]};
  }
  if(method==='PUT'&&path==='/api/ddns/configure'){Object.assign(config,clone(body));return {ret:0};}
  throw new Error('unexpected private API request');
 };
 return {data,state,calls,config,registry,api,run:extra=>reconcileLuckyManaged({load:()=>clone(data),gate:()=>true,api,registry,...extra})};
}
async function closed(promise){await assert.rejects(promise,/^Error: CPE managed Lucky reconciliation unavailable$/);}
test('independent API native creation uses native template and allocated identity without UDX auth or rewrites',async()=>{
 const f=native({owned:true}),service={...defaultApiService(),enabled:true},previous=clone(f.state);
 const result=await reconcileLuckyApi({load:()=>service,loadTemplate:()=>f.data,gate:()=>true,api:f.api,registry:f.registry});
 assert.equal(result.ready,true);assert.equal(result.created,true);assert.equal(result.keys.enabled,true);
 const post=f.calls.find(x=>x.method==='POST');assert.equal(post.path,'/api/webservice/rules');
 assert.equal(post.body.RuleKey,'');assert.equal(post.body.RuleName,apiRuleName);assert.equal(post.body.ListenPort,16802);
 const child=post.body.ProxyList[0];assert.equal(child.BasicAuthUserList,'');assert.equal(child.EnableBasicAuth,false);
 assert.equal(child.OtherParams.WebAuth,false);assert.deepEqual(child.Locations,['http://127.0.0.1:8317']);
 assert.equal(child.UseRuleGlobalAuthSettings,false);assert.ok(!JSON.stringify(post.body).includes(password));
 assert.deepEqual(f.state.rule.slice(0,previous.rule.length),previous.rule);assert.deepEqual(f.state.ddns,previous.ddns);assert.deepEqual(f.state.ssl,previous.ssl);
 const second=await reconcileLuckyApi({load:()=>service,loadTemplate:()=>f.data,gate:()=>true,api:f.api,registry:f.registry});
 assert.equal(second.ready,true);assert.equal(second.created,false);assert.equal(f.calls.filter(x=>x.method==='POST').length,1);
});
test('API native registry preserves explicit disables even if the disabled Lucky rule is later deleted',async()=>{
 const f=native({owned:true}),service={...defaultApiService(),enabled:true};
 const rule=apiRuleFromTemplate(f.data.seed.rule,service);rule.Enable=false;f.state.rule.push(rule);
 const options={load:()=>service,loadTemplate:()=>f.data,gate:()=>true,api:f.api,registry:f.registry};
 assert.equal((await reconcileLuckyApi(options)).disabled,true);assert.equal(f.registry.value.enabled,false);
 f.state.rule.pop();assert.equal((await reconcileLuckyApi(options)).disabled,true);
 assert.ok(f.calls.every(x=>x.method==='GET'));
});
test('foreign/unsafe API names or occupied listeners are preserved and optional failures stay isolated',async()=>{
 const service={...defaultApiService(),enabled:true};
 for(const mutate of [r=>{r.RuleKey='foreignID';},r=>{r.ListenIP='0.0.0.0';},r=>{r.ProxyList[0].EnableBasicAuth=true;},
  r=>{r.ProxyList[0].OtherParams.WebAuth=true;},r=>{r.ProxyList[0].Locations=['http://192.168.13.9:22'];},r=>{r.RuleName='foreign-owner';}]){
  const f=native({owned:true}),rule=apiRuleFromTemplate(f.data.seed.rule,service);mutate(rule);f.state.rule.push(rule);
  const previous=clone(f.state),out=await reconcileLuckyApi({load:()=>service,loadTemplate:()=>f.data,gate:()=>true,api:f.api,registry:f.registry});
  assert.equal(out.ready,false);assert.deepEqual(f.state,previous);assert.ok(f.calls.every(x=>x.method==='GET'));
 }
 const f=native();assert.equal((await reconcileLuckyApi({load:()=>null,api:f.api})).skipped,true);assert.equal(f.calls.length,0);
 assert.equal((await reconcileLuckyApi({load:()=>({...service,upstream:'http://127.0.0.1:22'}),api:f.api})).ready,false);assert.equal(f.calls.length,0);
 let restored=false;
 assert.equal((await reconcileLuckyApi({gate:()=>false,restore:()=>{restored=true;}})).ready,false);assert.equal(restored,false);
});
test('API health requires current owned scope and upstream401, never a webpage or redirects',async()=>{
 const service={...defaultApiService(),enabled:true},rule=apiRuleFromTemplate(material().seed.rule,service);
 const keys={version:1,hostname:service.publicHost,enabled:true,lucky_rule_key:rule.RuleKey,lucky_child_key:rule.ProxyList[0].Key};
 const calls=[],api=async()=>({ret:0,ruleList:[rule]});
 const fetch=async(url,options)=>{calls.push({url,options});return {status:401,body:{cancel:async()=>{}}};};
 assert.equal(await apiBackendReady(service,{api,keys,fetch}),true);assert.equal(calls.length,2);
 assert.equal(calls[0].options.headers.Authorization,undefined);assert.match(calls[1].options.headers.Authorization,/^Bearer /);
 assert.equal(await apiBackendReady(service,{api,keys,fetch:async()=>({status:200})}),false);
 rule.Enable=false;assert.equal(await apiBackendReady(service,{api,keys,fetch}),false);
 rule.Enable=true;rule.ProxyList[0].BasicAuthUserList='foreign:secret';assert.equal(await apiBackendReady(service,{api,keys,fetch}),false);
});
test('old restored Lucky configs get missing owned names with native allocated IDs in a separate registry',async()=>{
 const f=native(),unrelated={rule:clone(f.state.rule[0]),ddns:clone(f.state.ddns[0]),ssl:clone(f.state.ssl[0])};
 const result=await f.run();assert.equal(result.ready,true);assert.deepEqual(result.created,['rule','ddns','ssl']);
 assert.deepEqual(f.registry.value,{version:1,hostname:managedHostname,origin_sni:managedOrigin,lucky_rule_key:'generatedrule1',ddns_task_key:'generatedddns2',ssl_task_key:'generatedssl3'});
 assert.deepEqual(result.keys,f.registry.value);assert.deepEqual(f.data,material());
 const sslPost=f.calls.find(c=>c.method==='POST'&&c.path==='/api/ssl');
 assert.equal(sslPost.body.CertBase64,'');assert.equal(sslPost.body.KeyBase64,'');
 const rulePost=f.calls.find(c=>c.method==='POST'&&c.path==='/api/webservice/rules');
 assert.equal(rulePost.body.RuleKey,'');assert.equal(rulePost.body.DefaultProxy.Key,'');
 assert.equal(rulePost.body.DefaultProxy.GroupKey,'');
 for(const child of rulePost.body.ProxyList){assert.equal(child.Key,'');assert.equal(child.GroupKey,'');}
 assert.deepEqual(f.calls.filter(c=>c.method==='POST').map(c=>c.path),['/api/webservice/rules','/api/ddns','/api/ssl']);
 for(const kind of ['rule','ddns','ssl'])assert.deepEqual(f.state[kind][0],unrelated[kind]);
 assert.ok(f.calls.every(c=>c.method==='GET'||c.method==='POST'));
 const count=f.calls.filter(c=>c.method==='POST').length;
 assert.deepEqual((await f.run()).created,[]);assert.equal(f.calls.filter(c=>c.method==='POST').length,count);
});
test('existing safe entries retain credentials, data, certificate payload and explicit disables',async()=>{
 for(const kind of ['rule','ddns','ssl']){
  const f=native({owned:true});f.state[kind][1].Enable=false;
  f.state.rule[1].ProxyList[0].BasicAuthUserList='administrator:ChangedCredentialValue123';
  f.state.ddns[1].DNS.Secret='ChangedDedicatedAccountSecret';f.state.ssl[1].CertBase64='existing renewed private data';
  const previous=clone(f.state),result=await f.run();
  assert.equal(result.ready,false);assert.deepEqual(result.disabled,[kind]);assert.deepEqual(f.state,previous);
  assert.ok(f.calls.every(c=>c.method==='GET'));
 }
 const f=native({owned:true});delete f.state.rule[1].ProxyList[0].WebAuth;
 f.state.rule[1].ProxyList[0].BasicAuthRegConf='';
 f.state.rule[1].ProxyList[0].BasicAuthUserList='administrator:ChangedCredentialValue123';
 const previous=clone(f.state);assert.equal((await f.run()).ready,true);assert.deepEqual(f.state,previous);
});
test('unsafe existing identities, unrelated source scope and missing trusted hooks fail without any writes',async()=>{
 const patches=[f=>f.state.rule[1].ListenIP='0.0.0.0',f=>f.state.rule[1].ProxyList[0].Domains.push('unapproved.invalid'),
  f=>f.state.rule[1].ProxyList[0].Locations=['http://192.168.13.9:22'],f=>f.state.rule[1].ProxyList[0].EnableBasicAuth=false,
  f=>f.state.rule[1].ProxyList[0].OtherParams.BasicAuthRegConf='/public',f=>f.state.rule[1].ProxyList[0].OtherParams.AutoOptionsFirewall=true,
  f=>f.state.ddns[1].V4QueryIPEnable=true,f=>f.state.ddns[1].DNS.CallAPINetwork='tcp6',
  f=>f.state.ddns[1].DNS.ID='UnrelatedProviderAccountID',f=>f.state.ssl[1].ExtParams.acmeDomains.push('unapproved.invalid'),
  f=>f.state.ssl[1].MappingChangeScript='',f=>f.state.ssl[1].MappingPath='/etc/lucky/cert-sync/cpe5g-openwrt/current'];
 for(const patch of patches){const f=native({owned:true});patch(f);await closed(f.run());assert.ok(f.calls.every(c=>c.method==='GET'));}
});
test('all entries are checked before creating any missing entry; duplicate IDs fail closed',async()=>{
 const f=native({owned:true});f.state.rule.pop();f.state.ssl[1].MappingChangeScript='unapproved command';await closed(f.run());
 assert.ok(f.calls.every(c=>c.method==='GET'));
 const g=native({owned:true});g.state.rule.push(clone(g.state.rule[1]));await closed(g.run());assert.ok(g.calls.every(c=>c.method==='GET'));
});
test('returned IDs inconsistent with readback or absent owned readback never update manifest or registry',async()=>{
 const f=native(),before=clone(f.data),real=f.api;
 await closed(f.run({api:async(m,p,b)=>m==='POST'?{ret:0,RuleKey:'differentGeneratedID'}:real(m,p,b)}));
 assert.deepEqual(f.data,before);assert.ok(f.calls.every(c=>c.method==='GET'));
 const g=native(),base=g.api;
 await closed(g.run({api:async(m,p,b)=>m==='POST'?{ret:0}:base(m,p,b)}));assert.deepEqual(g.data,material());
});
test('an entry appearing or being disabled before creation is preserved instead of replaced',async()=>{
 const f=native(),base=f.api;let ruleReads=0;
 const result=await f.run({api:async(m,p,b)=>{
  if(m==='GET'&&p==='/api/webservice/rules'&&++ruleReads===2){const rule=clone(f.data.seed.rule);rule.Enable=false;f.state.rule.push(rule);}
  return base(m,p,b);
 }});assert.equal(result.ready,false);assert.deepEqual(result.disabled,['rule']);
 assert.equal(f.state.rule[1].Enable,false);assert.ok(f.calls.every(c=>c.method==='GET'));
});
test('differently keyed user entries owning the listener or origin domain are not displaced',async()=>{
 for(const kind of ['rule','ddns','ssl']){
  const f=native(),foreign=clone(f.data.seed[kind]);foreign[kind==='rule'?'RuleKey':kind==='ddns'?'TaskKey':'Key']='foreignOwner';
  foreign[kind==='rule'?'RuleName':kind==='ddns'?'TaskName':'Remark']='unrelated-owner';
  f.state[kind].push(foreign);const previous=clone(f.state);await closed(f.run());
  assert.deepEqual(f.state,previous);assert.ok(f.calls.every(c=>c.method==='GET'));
 }
});
test('a concurrent disable of an existing entry during missing-entry creation stays disabled',async()=>{
 const f=native({owned:true});f.state.rule.pop();const base=f.api;
 const result=await f.run({api:async(m,p,b)=>{const out=await base(m,p,b);if(m==='POST')f.state.ssl[1].Enable=false;return out;}});
 assert.deepEqual(result,{ready:false,skipped:false,created:['rule'],disabled:['ssl']});assert.equal(f.state.ssl[1].Enable,false);
 assert.ok(f.calls.every(c=>c.method==='GET'||c.method==='POST'));
});
test('pending restore and invalid seed suffix prevent API mutations',async()=>{
 const f=native();await closed(f.run({gate:()=>false}));assert.equal(f.calls.length,0);
 const g=native(),base=g.api;g.config.CustomDomainSuffix='example.test';
 const previous=clone(g.config);assert.equal((await g.run()).ready,true);
 assert.equal(g.config.CustomDomainSuffix,'example.test\njmsu.top\n');
 for(const key of Object.keys(previous).filter(x=>x!=='CustomDomainSuffix'))assert.deepEqual(g.config[key],previous[key]);
 assert.equal(g.calls.filter(c=>c.method==='PUT').length,1);
 await g.run();assert.equal(g.calls.filter(c=>c.method==='PUT').length,1);
 const h=material();h.seed.domain_suffix='example.invalid';assert.throws(()=>validateManagedSeed(h.seed,h.manifest));
});
test('seed validation requires bounded exact owned native scopes and matching manifest keys',()=>{
 const f=material();assert.deepEqual(validateManagedSeed(f.seed,f.manifest),f.seed);
 const patches=[v=>v.seed.rule.ProxyList[0].BasicAuthUserList='wrong:CredentialValueMoreThan24Chars',
  v=>v.seed.rule.ProxyList[0].BasicAuthUserList='cpe-temp:DifferentSeedCredentialValue123',
  v=>v.manifest.ssl_task_key='wrongID',v=>v.seed.rule.ListenPort=18443,v=>v.seed.rule.EnableTLS=true,
  v=>v.seed.rule.DefaultProxy.WebServiceType='reverseproxy',v=>v.seed.ddns.Records[0].SyncRecordData.fullDomainName='jmsu.top',
  v=>v.seed.ddns.V6GetIPScript='curl https://unapproved.invalid',v=>v.seed.ddns.DNS.Name='aliesa',
  v=>v.seed.ssl.ExtParams.acmeDNSSecret='differentPrivateSecret',v=>v.seed.ssl.AllSyncClient=true];
 for(const patch of patches){const v=material();patch(v);assert.throws(()=>validateManagedSeed(v.seed,v.manifest));}
});
test('partial native creation survives failure and resumes by names without duplicating or rewriting manifest',async()=>{
 const f=native(),base=f.api,before=clone(f.data);let interrupted=true;
 await closed(f.run({api:async(m,p,b)=>{
  if(m==='POST'&&p==='/api/ddns'&&interrupted){interrupted=false;throw Error('interrupted native task creation');}
  return base(m,p,b);
 }}));
 assert.equal(f.state.rule.length,2);assert.equal(f.registry.value,null);assert.deepEqual(f.data,before);
 const resumed=await f.run();assert.deepEqual(resumed.created,['ddns','ssl']);assert.equal(f.state.rule.length,2);
 assert.equal(f.registry.value.lucky_rule_key,f.state.rule[1].RuleKey);assert.deepEqual(f.data,before);
});
test('policy disable or manifest edits during API creation are preserved and prevent registry publication',async()=>{
 for(const change of [f=>f.data.policy.enabled=false,f=>f.data.manifest.password='NewAdministrativeCredentialValue123']){
  const f=native(),base=f.api;
  await closed(f.run({api:async(m,p,b)=>{const out=await base(m,p,b);if(m==='POST')change(f);return out;}}));
  assert.equal(f.registry.value,null);assert.equal(f.state.rule.length,2);assert.equal(f.state.ddns.length,1);
 }
 const g=native();g.data.policy.enabled=false;const disabled=await g.run();
 assert.deepEqual(disabled.disabled,['policy']);assert.equal(g.calls.length,0);
 const h=native();h.config.Enable=false;assert.deepEqual((await h.run()).disabled,['ddns-global']);assert.ok(h.calls.every(c=>c.method==='GET'));
});
test('atomic registry owns only identity keys and refuses malformed or insecure prior state',async()=>{
 const f=disk(),registry=new ManagedRegistry({paths:f.paths,rootBoundary:root});
 const keys={version:1,hostname:managedHostname,origin_sni:managedOrigin,lucky_rule_key:'actualRule',ddns_task_key:'actualDdns',ssl_task_key:'actualSsl'};
 const manifest=fs.readFileSync(f.paths.manifest),policy=fs.readFileSync(f.paths.policy);assert.equal(registry.read(),null);
 const release=registry.acquire();try{registry.write(keys,()=>{});}finally{release();}
 assert.deepEqual(registry.read(),keys);assert.equal(fs.statSync(f.paths.registry).mode&0o777,0o600);assert.equal(fs.existsSync(f.paths.lock),false);
 assert.deepEqual(fs.readFileSync(f.paths.manifest),manifest);assert.deepEqual(fs.readFileSync(f.paths.policy),policy);
 const prior=fs.readFileSync(f.paths.registry);assert.throws(()=>registry.write({...keys,lucky_rule_key:'newRule'},()=>{throw Error('changed authorization');}));
 assert.deepEqual(fs.readFileSync(f.paths.registry),prior);
 for(const patch of [{hostname:'unapproved.invalid'},{origin_sni:'unapproved.invalid'},{ssl_task_key:''},{password:'unapprovedField'}])assert.throws(()=>validateManagedKeys({...keys,...patch}));
 fs.chmodSync(f.paths.registry,0o644);assert.throws(()=>registry.read());fs.chmodSync(f.paths.registry,0o600);
 fs.renameSync(f.paths.registry,f.paths.registry+'.real');fs.symlinkSync(f.paths.registry+'.real',f.paths.registry);assert.throws(()=>registry.read());
});
test('same-process reconciliation and a live registry lease cannot be taken over',async()=>{
 const f=native(),base=f.api;let checked=false;
 await f.run({api:async(m,p,b)=>{
  if(!checked){checked=true;await closed(f.run());await closed(f.run());}
  return base(m,p,b);
 }});assert.equal(f.registry.locked,false);
 const g=disk(),registry=new ManagedRegistry({paths:g.paths,rootBoundary:root});const release=registry.acquire();
 try{assert.throws(()=>registry.acquire());}finally{release();}
 assert.equal(fs.existsSync(g.paths.lock),false);
});
test('orphaned retained restore settings do not block boot without operative wrtbak',()=>{
 const f=disk();assert.equal(restoreTerminal({paths:f.paths,rootBoundary:root,run:()=>assert.fail('orphan UCI should not be queried')}),true);
 f.put(f.paths.restoreService,'#!/bin/sh\n');fs.chmodSync(f.paths.restoreService,0o700);
 assert.equal(restoreTerminal({paths:f.paths,rootBoundary:root,run:(bin)=>{assert.equal(bin,'/bin/sh');throw Object.assign(Error('absent wrtbak'),{status:1});}}),true);
});
test('private ROM seed supersedes restored /etc seed; malformed ROM never falls back',()=>{
 const f=disk();assert.deepEqual(f.load(),f.data);
 const stale=clone(f.data.seed);stale.domain_suffix='invalid.example';f.put(f.paths.seed,stale);f.put(f.paths.romSeed,f.data.seed);f.put(f.paths.romManifest,f.data.manifest);
 assert.deepEqual(f.load(),{...f.data,seedManifest:f.data.manifest});
 f.put(f.paths.romSeed,'invalid private JSON');assert.throws(()=>f.load());
 const g=disk();fs.unlinkSync(g.paths.seed);assert.throws(()=>g.load());
 fs.unlinkSync(g.paths.manifest);assert.equal(g.load(),null);
});
test('retained manifest reference IDs may differ from ROM while immutable credentials remain coherent',async()=>{
 const f=disk();f.put(f.paths.romSeed,f.data.seed);f.put(f.paths.romManifest,f.data.manifest);
 const retained={...f.data.manifest,lucky_rule_key:'retainedRuleReference',ddns_task_key:'retainedDnsReference',ssl_task_key:'retainedSslReference'};
 f.put(f.paths.manifest,retained);const loaded=f.load();assert.deepEqual(loaded.seedManifest,f.data.manifest);assert.deepEqual(loaded.manifest,retained);
 const service=native({owned:true});assert.equal((await service.run({load:f.load})).ready,true);
 assert.deepEqual(JSON.parse(fs.readFileSync(f.paths.manifest)),retained);
 for(const patch of [{password:'DifferentAdministrativeCredentialValue123'},{origin_header_secret:'b'.repeat(64)}]){
  f.put(f.paths.manifest,{...retained,...patch});assert.throws(()=>f.load());
 }
});
test('root-owned 0600 bounded regular files and every containing directory are required',()=>{
 for(const pathKey of ['seed','manifest']){
  const f=disk();fs.chmodSync(f.paths[pathKey],0o644);assert.throws(()=>f.load());
  const g=disk(),file=g.paths[pathKey];fs.renameSync(file,file+'.real');fs.symlinkSync(file+'.real',file);assert.throws(()=>g.load());
 }
 const f=disk();fs.chownSync(f.paths.seed,65534,65534);assert.throws(()=>f.load());fs.chownSync(f.paths.seed,0,0);
 const g=disk();g.put(g.paths.seed,'x'.repeat(65537));assert.throws(()=>g.load());
 const h=disk();fs.chmodSync(dirname(h.paths.seed),0o720);assert.throws(()=>h.load());fs.chmodSync(dirname(h.paths.seed),0o700);
 const i=disk();fs.unlinkSync(i.paths.seed);execFileSync('mkfifo',[i.paths.seed]);assert.throws(()=>i.load());
 const j=disk(),dir=dirname(j.paths.seed);fs.renameSync(dir,dir+'.real');fs.symlinkSync(dir+'.real',dir);assert.throws(()=>j.load());
});
test('restore gates accept only terminal restore decisions and absent disabled settings',()=>{
 const f=disk();f.put(f.paths.restoreGate,{state:'restoring'});
 f.put(f.paths.restoreService,'#!/bin/sh\n');fs.chmodSync(f.paths.restoreService,0o700);
 const options={paths:f.paths,rootBoundary:root,run:bin=>bin==='/sbin/uci'?'1\n':''};
 assert.equal(restoreTerminal(options),false);
 for(const state of ['restored','already_done','no_backup','failed_final','disabled']){f.put(f.paths.restoreGate,{state});assert.equal(restoreTerminal(options),true);}
 assert.equal(restoreTerminal({...options,run:bin=>bin==='/sbin/uci'?'0\n':''}),true);
 assert.equal(restoreTerminal({...options,run:()=>{throw Object.assign(new Error('missing'),{status:1});}}),true);
 assert.throws(()=>restoreTerminal({...options,run:()=>{throw new Error('uci unavailable');}}));
});
test('transport uses fixed loopback and private token header; errors never expose provider or API secrets',async()=>{
 const f=disk(),seen=[];
 const api=luckyApi({paths:f.paths,rootBoundary:root,fetch:async(url,options)=>{
  seen.push({url,options});return {status:200,text:async()=>JSON.stringify({ret:0,list:[]})};
 }});
 assert.deepEqual(await api('GET','/api/ssl'),{ret:0,list:[]});
 assert.equal(seen[0].url,'http://127.0.0.1:16601/api/ssl');assert.equal(seen[0].options.headers.openToken,'FixtureOpenTokenOnly');
 const bad=luckyApi({paths:f.paths,rootBoundary:root,fetch:async()=>{throw new Error('private API secret fixture');}});
 await closed(bad('GET','/api/ssl'));
 let error='';assert.equal(await managedMain({allowArgs:true,reconcile:()=>{throw new Error('private provider secret');},stderr:x=>error+=x}),1);
 assert.equal(error,'CPE managed Lucky reconciliation unavailable\n');
});
test('changed private seed/manifest before mutation stops bootstrap; missing optional feature is silent',async()=>{
 const f=native();let loads=0;
 await closed(f.run({load:()=>{const next=clone(f.data);if(++loads>1)next.manifest.password='ChangedAdministrativePasswordValue123';return next;}}));
 assert.ok(f.calls.every(c=>c.method==='GET'));
 const g=native();assert.deepEqual(await g.run({load:()=>null}),{ready:false,skipped:true,created:[],disabled:[]});assert.equal(g.calls.length,0);
 assert.equal(await managedMain({allowArgs:true,reconcile:async()=>({skipped:true}),stderr:()=>assert.fail('unexpected output')}),0);
});
test('import has no filesystem/API side effects and CLI arguments cannot redirect trusted paths',()=>{
 const module=new URL('../Scripts/cpe5g-ipv6/reconcile-lucky-managed.mjs',import.meta.url).href;
 assert.equal(execFileSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(module)});process.stdout.write('import-only');`],{encoding:'utf8'}),'import-only');
 try{execFileSync(process.execPath,[new URL(module).pathname,'--seed','/untrusted.json'],{encoding:'utf8',stdio:['ignore','pipe','pipe']});assert.fail('CLI accepted redirected paths');}
 catch(error){assert.equal(error.status,1);assert.equal(error.stdout,'');assert.equal(error.stderr,'CPE managed Lucky reconciliation unavailable\n');}
});
