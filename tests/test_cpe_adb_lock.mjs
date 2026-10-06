import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import net from 'node:net';
import {spawn,execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {join} from 'node:path';
import {setTimeout as wait} from 'node:timers/promises';
import {shell,packet} from '../Scripts/cpe5g-ipv6/adb.mjs';

const module=new URL('../Scripts/cpe5g-ipv6/adb.mjs',import.meta.url).href;
async function fixture(t,{hold=40,fin=0,authFirst=false,silent=false,heartbeat=false}={}){
 const root=fs.mkdtempSync('/tmp/cpe-adb-lock-'),lockDirectory=join(root,'locks');
 const state={connections:0,active:0,maximum:0,closeReplies:0,finishes:0,opened:[],sockets:new Set()};
 const server=net.createServer({allowHalfOpen:true},socket=>{
  state.connections++;state.active++;state.maximum=Math.max(state.maximum,state.active);state.sockets.add(socket);
  let pending=Buffer.alloc(0),timer,interval;
  socket.on('error',()=>{});socket.on('close',()=>{clearTimeout(timer);clearInterval(interval);state.active--;state.sockets.delete(socket);});
  socket.on('end',()=>{timer=setTimeout(()=>{state.finishes++;socket.end();},fin);});
  socket.on('data',chunk=>{
   pending=Buffer.concat([pending,chunk]);
   while(pending.length>=24){
    const size=pending.readUInt32LE(12);if(pending.length<24+size)return;
    const name=pending.subarray(0,4).toString(),body=pending.subarray(24,24+size);pending=pending.subarray(24+size);
    if(silent)continue;
    if(name==='CNXN')socket.write(packet(authFirst&&state.connections===1?'AUTH':'CNXN',0x01000000,4096,'device::\0'));
    if(name==='OPEN'){
     const command=body.toString().replace(/^shell:/,'').replace(/\0$/,'');state.opened.push(command);
     socket.write(packet('OKAY',7,1));
     if(heartbeat)interval=setInterval(()=>socket.write(packet('WRTE',7,1,'.')),10);
     else timer=setTimeout(()=>socket.write(Buffer.concat([packet('WRTE',7,1,command),packet('CLSE',7,1)])),hold);
    }
    if(name==='CLSE')state.closeReplies++;
   }
  });
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 t.after(async()=>{for(const socket of state.sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));fs.rmSync(root,{recursive:true,force:true});});
 const port=server.address().port,call=(command,options={})=>shell('127.0.0.1',port,command,{timeout:2000,lockDirectory,...options});
 return {state,root,lockDirectory,port,call};
}
async function until(predicate){
 const deadline=Date.now()+3000;
 while(!predicate()){assert.ok(Date.now()<deadline,'expected transport phase was not reached');await wait(5);}
}
function childCall(t,{port,lockDirectory,command='child',timeout=2000}){
 const source=`import {shell} from ${JSON.stringify(module)};console.log('started');
try{const output=await shell('127.0.0.1',${port},${JSON.stringify(command)},{timeout:${timeout},lockDirectory:${JSON.stringify(lockDirectory)}});console.log(JSON.stringify({output}));}
catch(error){console.log(JSON.stringify({error:error.message}));process.exitCode=1;}`;
 const child=spawn(process.execPath,['--input-type=module','-e',source],{stdio:['ignore','pipe','pipe']});
 let stdout='',stderr='';child.stdout.on('data',chunk=>stdout+=chunk);child.stderr.on('data',chunk=>stderr+=chunk);
 const done=new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',(code,signal)=>resolve({code,signal,stdout,stderr}));});
 t.after(()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');});
 return {child,done,started:()=>stdout.includes('started\n')};
}
function lockPath(f){return join(f.lockDirectory,createHash('sha256').update(JSON.stringify(['127.0.0.1',f.port])).digest('hex')+'.lock');}

test('same-process calls serialize through delayed CLSE/FIN and retain one shared inode',async t=>{
 const f=await fixture(t,{hold:35,fin:90});
 const results=await Promise.all(['one','two','three','four'].map(command=>f.call(command)));
 assert.deepEqual(results,['one','two','three','four']);assert.equal(f.state.maximum,1);
 assert.equal(f.state.closeReplies,4);assert.equal(f.state.finishes,4);
 assert.equal(fs.statSync(lockPath(f)).size,0);assert.equal(fs.statSync(lockPath(f)).mode&0o777,0o600);
});

test('separate real Node processes cannot overlap a transport or its FIN grace',async t=>{
 const f=await fixture(t,{hold:100,fin:65});
 const children=Array.from({length:4},(_,index)=>childCall(t,{...f,command:'process-'+index}));
 const results=await Promise.all(children.map(child=>child.done));
 for(const result of results){assert.equal(result.code,0,result.stderr);assert.equal(result.signal,null);}
 assert.equal(f.state.maximum,1);assert.equal(f.state.closeReplies,4);assert.equal(f.state.finishes,4);
});

test('an aborted or bounded-out waiter never connects or steals the live owner',async t=>{
 const f=await fixture(t,{silent:true}),ownerAbort=new AbortController();
 const owner=f.call('owner',{signal:ownerAbort.signal});const ownerRejected=assert.rejects(owner,{name:'AbortError'});
 await until(()=>f.state.connections===1);
 const abort=new AbortController(),started=Date.now();
 const waiter=f.call('waiter',{signal:abort.signal});const cancelled=assert.rejects(waiter,{name:'AbortError'});
 setTimeout(()=>abort.abort(),35);await cancelled;assert.ok(Date.now()-started<400);
 await assert.rejects(f.call('bounded',{lockTimeout:55}),/lock timeout/);
 assert.equal(f.state.connections,1);assert.equal(f.state.active,1);
 ownerAbort.abort();await ownerRejected;
});

test('SIGKILL releases the kernel lock without stale PID records or deleting its inode',async t=>{
 const f=await fixture(t,{hold:250});
 const owner=childCall(t,{...f,command:'dead-owner'});await until(()=>f.state.opened.includes('dead-owner'));
 const inode=fs.statSync(lockPath(f)).ino;
 const replacement=childCall(t,{...f,command:'replacement'});await until(replacement.started);
 await wait(60);assert.equal(f.state.connections,1,'a live lock must never be reclaimed by age');
 owner.child.kill('SIGKILL');assert.equal((await owner.done).signal,'SIGKILL');
 const result=await replacement.done;assert.equal(result.code,0,result.stderr);assert.ok(result.stdout.includes('replacement'));
 assert.equal(fs.statSync(lockPath(f)).ino,inode);assert.equal(f.state.maximum,1);
});

test('an owner released after the wait deadline cannot be acquired by a delayed event loop',async t=>{
 const f=await fixture(t);fs.mkdirSync(f.lockDirectory,{mode:0o700});
 const source=`import fs from 'node:fs';import {execFileSync} from 'node:child_process';import {setTimeout as wait} from 'node:timers/promises';
const fd=fs.openSync(${JSON.stringify(lockPath(f))},'a+',0o600);execFileSync('/usr/bin/flock',['-x','-n','-E','75','3'],{stdio:['ignore','ignore','ignore',fd]});
console.log('held');await wait(80);fs.closeSync(fd);`;
 const child=spawn(process.execPath,['--input-type=module','-e',source],{stdio:['ignore','pipe','pipe']});
 let stdout='';child.stdout.on('data',chunk=>stdout+=chunk);
 const exited=new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',code=>resolve(code));});
 t.after(()=>{if(child.exitCode===null)child.kill('SIGKILL');});
 await until(()=>stdout.includes('held'));
 const pending=f.call('must-not-connect',{lockTimeout:40}),rejected=assert.rejects(pending,/lock timeout/);
 const blocking=setTimeout(()=>{const until=Date.now()+110;while(Date.now()<until){}},10);
 try{await rejected;}finally{clearTimeout(blocking);}
 assert.equal(await exited,0);assert.equal(f.state.connections,0);
 assert.equal(await f.call('after-deadline'),'after-deadline');
});

test('authentication failure and absolute transport timeout release only after TCP close',async t=>{
 const f=await fixture(t,{authFirst:true,hold:15});
 const failed=f.call('auth'),rejected=assert.rejects(failed,/requires authentication/);
 const next=f.call('after-auth');await rejected;assert.equal(await next,'after-auth');assert.equal(f.state.maximum,1);
 const stalled=await fixture(t,{silent:true});
 await assert.rejects(stalled.call('timeout',{timeout:45}),/Private ADB timeout/);
 const child=childCall(t,{...stalled,timeout:45});const result=await child.done;
 assert.equal(result.code,1);assert.ok(result.stdout.includes('Private ADB timeout'));assert.equal(stalled.state.maximum,1);
});

test('continuous WRTE heartbeat cannot extend the command deadline indefinitely',async t=>{
 const f=await fixture(t,{heartbeat:true}),started=Date.now();
 await assert.rejects(f.call('never-closes',{timeout:90}),/Private ADB timeout/);
 assert.ok(Date.now()-started<500);await until(()=>f.state.active===0);
 assert.equal(f.state.closeReplies,0);
});

test('cancellation during CLSE/FIN closure remains prompt and releases the endpoint',async t=>{
 const f=await fixture(t,{hold:5,fin:300}),abort=new AbortController();
 const pending=f.call('closing',{signal:abort.signal}),rejected=assert.rejects(pending,{name:'AbortError'});
 await until(()=>f.state.closeReplies===1);
 const started=Date.now();abort.abort();await rejected;assert.ok(Date.now()-started<400);
 assert.equal(await f.call('after-closing-abort'),'after-closing-abort');
});

test('another host/port has an independent lock while one endpoint is held',async t=>{
 const held=await fixture(t,{silent:true}),other=await fixture(t,{hold:5});
 const abort=new AbortController(),pending=held.call('held',{signal:abort.signal});const rejected=assert.rejects(pending,{name:'AbortError'});
 await until(()=>held.state.connections===1);
 assert.equal(await shell('127.0.0.1',other.port,'independent',{timeout:250,lockDirectory:held.lockDirectory}),'independent');
 abort.abort();await rejected;
});

test('unsafe directories, symlink/FIFO/hardlink/content lock files fail before connecting',async t=>{
 const f=await fixture(t),outside=join(f.root,'outside');fs.mkdirSync(outside,{mode:0o700});
 fs.symlinkSync(outside,f.lockDirectory);await assert.rejects(f.call('unsafe'));fs.unlinkSync(f.lockDirectory);
 fs.mkdirSync(f.lockDirectory,{mode:0o700});
 for(const mode of [0o777,0o750]){fs.chmodSync(f.lockDirectory,mode);await assert.rejects(f.call('unsafe'),/lock unavailable/);}
 fs.chmodSync(f.lockDirectory,0o700);
 const file=lockPath(f),target=join(outside,'untouched');fs.writeFileSync(target,'sentinel',{mode:0o600});
 fs.symlinkSync(target,file);await assert.rejects(f.call('unsafe'));fs.unlinkSync(file);assert.equal(fs.readFileSync(target,'utf8'),'sentinel');
 execFileSync('mkfifo',[file]);await assert.rejects(f.call('unsafe'),/lock unavailable/);fs.unlinkSync(file);
 fs.writeFileSync(file,'untrusted',{mode:0o600});await assert.rejects(f.call('unsafe'),/lock unavailable/);fs.unlinkSync(file);
 fs.writeFileSync(file,'',{mode:0o600});fs.linkSync(file,join(outside,'alias'));await assert.rejects(f.call('unsafe'),/lock unavailable/);fs.unlinkSync(file);fs.unlinkSync(join(outside,'alias'));
 fs.writeFileSync(file,'',{mode:0o666});fs.chmodSync(file,0o666);await assert.rejects(f.call('unsafe'),/lock unavailable/);fs.unlinkSync(file);
 if(process.getuid()===0){fs.writeFileSync(file,'',{mode:0o600});fs.chownSync(file,65534,65534);await assert.rejects(f.call('unsafe'),/lock unavailable/);fs.unlinkSync(file);}
 assert.equal(f.state.connections,0);assert.equal(await f.call('safe-again'),'safe-again');
});
