import {test} from 'node:test';
import assert from 'node:assert/strict';
import {provision,hashOf,verifiedHash,monitor} from '../Scripts/cpe5g-ipv6/audit-bootstrap.mjs';
import {setTimeout as wait} from 'node:timers/promises';
const body=Buffer.from('auditor-fixture'),hash=hashOf(body);
test('matching companion needs no listener or firewall rule',async()=>{
 assert.equal(await provision({body,transport:async()=>hash+'  /tmp/audit',nft:()=>{throw Error('unexpected firewall');}}),false);
});
test('missing companion is verified before publication and firewall is removed',async()=>{
 const calls=[],rules=[];const transport=async(h,p,c)=>{calls.push(c);if(c.startsWith('sha256sum'))return '';if(c.includes('wget'))return hash+'  file.new';return 'CPE6_AUDIT_READY';};
 const nft=args=>{rules.push(args);return args[0]==='-a'?'comment "cpe6-audit-bootstrap" # handle 42':'';};
 assert.equal(await provision({body,transport,nft,listenAddress:'127.0.0.1',port:0}),true);
 assert.match(calls[1],/wget.*&& sha256sum/);
 assert.match(calls[2],/chmod 700.*&& mv/);
 assert.deepEqual(rules.at(-1),['delete','rule','inet','fw4','input','handle','42']);
 assert.ok(rules[0].includes('usb0'));assert.ok(rules[0].includes('192.168.66.1'));
});
test('bad transfer checksum never publishes, and cleans listener/rule',async()=>{
 const calls=[],rules=[];const transport=async(h,p,c)=>{calls.push(c);return 'bad  file';};
 const nft=args=>{rules.push(args);return args[0]==='-a'?'comment "cpe6-audit-bootstrap" # handle 43':'';};
 await assert.rejects(provision({body,transport,nft,listenAddress:'127.0.0.1',port:0}),/checksum mismatch/);
 assert.ok(!calls.some(c=>c.includes('&& mv')));
 assert.equal(rules.at(-1).at(-1),'43');
});
test('aborted modem transfer releases the temporary listener and firewall rule',async()=>{
 const abort=new AbortController(),rules=[];
 const transport=async(h,p,c,{signal})=>{
  if(c.startsWith('sha256sum'))return '';
  return new Promise((resolve,reject)=>{
   signal.addEventListener('abort',()=>reject(Error('transfer aborted')),{once:true});
   queueMicrotask(()=>abort.abort());
  });
 };
 const nft=args=>{rules.push(args);return args[0]==='-a'?'comment "cpe6-audit-bootstrap" # handle 44':'';};
 await assert.rejects(provision({body,transport,nft,signal:abort.signal,listenAddress:'127.0.0.1',port:0}),/transfer aborted/);
 assert.deepEqual(rules.at(-1),['delete','rule','inet','fw4','input','handle','44']);
});
test('hash parser requires exact first digest',()=>{assert.equal(verifiedHash('prefix '+hash,hash),false);assert.equal(verifiedHash(hash+'  file',hash),true);});

test('stalled modem maintenance does not delay serialized local failover',async()=>{
 const abort=new AbortController();let calls=0,active=0,maxActive=0,maintenanceCalls=0,maintenancePending=false,pendingAtThird=false;
 await monitor({signal:abort.signal,localInterval:1,maintenanceInterval:1,
  localReconcile:async()=>{
   active++;maxActive=Math.max(maxActive,active);await wait(2);active--;
   if(++calls===3){pendingAtThird=maintenancePending;abort.abort();}
  },
  maintenance:async()=>{
   maintenanceCalls++;maintenancePending=true;
   await new Promise(resolve=>abort.signal.addEventListener('abort',resolve,{once:true}));
   maintenancePending=false;
  }
 });
 assert.equal(calls,3);assert.equal(maxActive,1);assert.equal(maintenanceCalls,1);assert.equal(pendingAtThird,true);
});
test('maintenance is sequential and graceful abort waits for cleanup',async()=>{
 const abort=new AbortController();let calls=0,active=0,maxActive=0,cleaned=false;
 await monitor({signal:abort.signal,localInterval:1,maintenanceInterval:1,
  localReconcile:()=>{},
  maintenance:async()=>{
   active++;maxActive=Math.max(maxActive,active);
   try{await wait(2);if(++calls===3)abort.abort();}
   finally{await wait(1);active--;cleaned=true;}
  }
 });
 assert.equal(calls,3);assert.equal(maxActive,1);assert.equal(active,0);assert.equal(cleaned,true);
});
test('local reconciliation errors retry without preventing modem work',async()=>{
 const abort=new AbortController(),errors=[];let calls=0,maintenanceCalls=0;
 await monitor({signal:abort.signal,localInterval:1,maintenanceInterval:1,
  localReconcile:()=>{if(++calls===1)throw Error('unavailable netifd');abort.abort();},
  maintenance:()=>{maintenanceCalls++;},report:(label,e)=>errors.push([label,e.message])
 });
 assert.equal(calls,2);assert.equal(maintenanceCalls,1);
 assert.deepEqual(errors,[['local IPv4 reconciliation','unavailable netifd']]);
});

import {withRouteAudit} from '../Scripts/cpe5g-ipv6/adb.mjs';
import {execFileSync} from 'node:child_process';
test('no companion refuses add before vendor ip; preserves non-route commands',()=>{
 assert.equal(withRouteAudit('echo private-probe'),'echo private-probe');
 const script=withRouteAudit('ip -6 route add 2001:db8::/64; printf "exit=%s" "$?"')
  .replaceAll('/tmp/cpe6-maint/route-audit','/nonexistent-cpe6-test-audit')
  .replaceAll('/sbin/ip','echo unexpected-vendor-command');
 assert.equal(execFileSync('sh',['-c',script],{encoding:'utf8'}),'exit=1');
});
