import assert from 'node:assert/strict';
import net from 'node:net';
import {shell,packet} from '../Scripts/cpe5g-ipv6/adb.mjs';
async function scenario(kind){
 const server=net.createServer(sock=>{
  let pending=Buffer.alloc(0);
  sock.on('error',()=>{});sock.on('data',chunk=>{pending=Buffer.concat([pending,chunk]);while(pending.length>=24){const len=pending.readUInt32LE(12);if(pending.length<24+len)return;const name=pending.subarray(0,4).toString();pending=pending.subarray(24+len);
   if(name==='CNXN')sock.write(packet(kind==='auth'?'AUTH':'CNXN',0x01000000,4096,'device::\0'));
   if(name==='OPEN'){
    if(kind==='closed'){sock.end();return;}
    sock.write(packet('OKAY',7,1));let w=packet('WRTE',7,1,'bounded-output');
    if(kind==='corrupt')w[16]^=1;
    if(kind==='wrong')w=packet('WRTE',7,9,'bounded-output');
    sock.write(w.subarray(0,9));setTimeout(()=>{sock.write(Buffer.concat([w.subarray(9),packet('CLSE',7,1)]));},5);
   }
  }});
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try{return await shell('127.0.0.1',server.address().port,'true',{timeout:300,maxBytes:1024});}
 finally{await new Promise(r=>server.close(r));}
}
assert.equal(await scenario('ok'),'bounded-output');
await assert.rejects(scenario('auth'),/requires authentication/);
await assert.rejects(scenario('corrupt'),/checksum/);
await assert.rejects(scenario('wrong'),/Wrong ADB stream/);
await assert.rejects(scenario('closed'),/prematurely/);
assert.throws(()=>packet('BOGUS'),/Invalid ADB frame/);
// Cancellation must interrupt a silent transport; an idle socket timeout can
// otherwise outlive netifd's five-second teardown grace period.
const controller=new AbortController();let closed;
const closure=new Promise(r=>{closed=r;});
const held=net.createServer(socket=>{socket.on('error',()=>{});socket.on('close',closed);socket.resume();});
await new Promise(r=>held.listen(0,'127.0.0.1',r));
const started=Date.now(),pending=shell('127.0.0.1',held.address().port,'held',{signal:controller.signal});
setTimeout(()=>controller.abort(),25);
await assert.rejects(pending,{name:'AbortError'});await closure;
assert.ok(Date.now()-started<1000,'abort must close the socket promptly');
await new Promise(r=>held.close(r));
await assert.rejects(shell('127.0.0.1',1,'never-connect',{signal:controller.signal}),{name:'AbortError'});
console.log('CPE private ADB transport passed');
