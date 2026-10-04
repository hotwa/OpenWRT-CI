import {test} from 'node:test';import assert from 'node:assert/strict';
import {reconcile} from '../Scripts/cpe5g-ipv6/local-failover.mjs';
const original={dst:'default',gateway:'192.0.2.1',dev:'pppoe-wan',protocol:'static',metric:10};
function fixture(route=original){
 let routes=[{...route}],ledger=null;const calls=[],health={wan:'offline','5G':'online'};
 const wan={up:true,l3_device:route.dev,'ipv4-address':[{address:route.prefsrc}],route:[{target:'0.0.0.0',mask:0,nexthop:route.gateway}]};
 const run=(bin,a)=>{
  if(bin==='ubus')return JSON.stringify(wan);
  if(a[0]==='-j')return JSON.stringify(routes);
  calls.push(a);const metric=Number(a[a.indexOf('metric')+1]);
  if(a[2]==='add')routes.push({...route,metric,protocol:a[a.indexOf('proto')+1]});
  else if(a[2]==='del')routes=routes.filter(r=>r.metric!==metric);
  return '';
 };
 const opts={run,readStatus:n=>health[n],readLedger:()=>ledger,saveLedger:r=>ledger={...r},clearLedger:()=>ledger=null};
 return {opts,calls,health,wan,get routes(){return routes;},get ledger(){return ledger;},set routes(r){routes=r;}};
}
test('WAN upstream failure demotes main default but preserves a probe route; recovery restores WAN',()=>{
 const f=fixture();reconcile(f.opts);assert.deepEqual(f.routes.map(r=>r.metric),[1000]);assert.equal(f.routes[0].protocol,'197');assert.deepEqual(f.calls.map(a=>a[2]),['add','del']);
 reconcile(f.opts);assert.equal(f.calls.length,2,'offline reconcile is idempotent');
 f.health.wan='online';reconcile(f.opts);assert.deepEqual(f.routes,[original]);assert.equal(f.ledger,null);assert.deepEqual(f.calls.slice(2).map(a=>a[2]),['add','del']);
});
test('unknown WAN or offline SIM leaves defaults untouched',()=>{for(const [w,s] of [['unknown','online'],['offline','offline']]){const f=fixture();f.health.wan=w;f.health['5G']=s;reconcile(f.opts);assert.deepEqual(f.routes,[original]);assert.equal(f.calls.length,0);}});
test('foreign tagged routes are rejected and never deleted',()=>{const f=fixture();f.routes=[{...original,protocol:'197',metric:1000}];assert.throws(()=>reconcile(f.opts),/foreign/);assert.equal(f.calls.length,0);});
test('WAN gateway change never restores the obsolete gateway',()=>{const f=fixture();reconcile(f.opts);f.wan.route[0].nexthop='192.0.2.9';f.health.wan='online';reconcile(f.opts);assert.equal(f.ledger,null);assert.ok(!f.calls.slice(2).some(a=>a[2]==='add'));});
test('interrupted mutation restores from write-ahead ledger',()=>{const f=fixture();reconcile(f.opts);f.routes=[];f.health.wan='online';reconcile(f.opts);assert.deepEqual(f.routes,[original]);assert.equal(f.ledger,null);});

test('DHCP Ethernet default restores source, protocol and onlink flag',()=>{
 const route={...original,dev:'wan',protocol:'dhcp',prefsrc:'192.0.2.10',flags:['onlink']};const f=fixture(route);
 reconcile(f.opts);assert.ok(f.calls[0].includes('src'));assert.ok(f.calls[0].includes('onlink'));
 f.health.wan='online';reconcile(f.opts);assert.deepEqual(f.routes,[route]);
});
test('failed fallback installation preserves the original WAN default',()=>{
 const f=fixture();const run=f.opts.run;f.opts.run=(b,a)=>{if(a[2]==='add')throw Error('route add failure');return run(b,a);};
 assert.throws(()=>reconcile(f.opts),/route add failure/);assert.deepEqual(f.routes,[original]);assert.ok(f.ledger);
});
