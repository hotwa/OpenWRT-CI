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
console.log('CPE private ADB transport passed');
