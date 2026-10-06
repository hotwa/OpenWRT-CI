// Minimal legacy ADB transport for the private, physically attached UDX710.
// Authentication-required daemons fail closed; this never provisions a key.
import net from 'node:net';
import fs from 'node:fs';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {dirname,resolve,join} from 'node:path';
import {performance} from 'node:perf_hooks';
import {setTimeout as delay} from 'node:timers/promises';
const codes = Object.fromEntries(['CNXN','AUTH','OPEN','OKAY','WRTE','CLSE'].map(s=>[s,Buffer.from(s).readUInt32LE()]));
const cancelled=()=>Object.assign(Error('Private ADB cancelled'),{name:'AbortError'});
const lockUnavailable=()=>Error('Private ADB lock unavailable');
function directory(path,uid,privateDirectory=false){
 // Only the root-owned sticky /tmp may be writable by other users. Every
 // other parent is controlled by root/the caller; the runtime directory is
 // strictly private. O_NOFOLLOW alone would not protect parent components.
 const target=resolve(path),parents=[];let current=target;
 while(true){parents.push(current);if(current==='/')break;current=dirname(current);}
 for(const parent of parents.reverse()){
  const stat=fs.lstatSync(parent),temporary=parent==='/tmp'&&stat.uid===0&&(stat.mode&0o1777)===0o1777;
  if(!stat.isDirectory()||stat.isSymbolicLink()||![0,uid].includes(stat.uid)||
   ((stat.mode&0o022)&&!temporary)||
   (parent===target&&privateDirectory&&(stat.uid!==uid||(stat.mode&0o077))))throw lockUnavailable();
 }
}
async function tryLock(fd,signal,remaining){
 // flock operates on the inherited open-file-description. The parent keeps
 // its FD after this short child exits, so the lock lasts until our TCP close
 // and is released by the kernel if the owner dies (including SIGKILL).
 return new Promise((resolve,reject)=>{
  const child=spawn('/usr/bin/flock',['-x','-n','-E','75','3'],{
   stdio:['ignore','ignore','ignore',fd],signal,timeout:Math.max(1,Math.min(1000,Math.ceil(remaining))),killSignal:'SIGKILL'
  });let failure;
  child.once('error',error=>{failure=error;});
  child.once('close',(code,term)=>{
   if(signal?.aborted){reject(cancelled());return;}
   if(failure||term||![0,75].includes(code)){reject(lockUnavailable());return;}
   resolve(code===0);
  });
 });
}
async function acquire(host,port,{lockTimeout,lockDirectory,signal}){
 if(signal?.aborted)throw cancelled();
 const uid=process.getuid(),root=resolve(lockDirectory||`/tmp/cpe5g-adb-${uid}`);
 directory(dirname(root),uid);
 try{fs.mkdirSync(root,{mode:0o700});}catch(error){if(error.code!=='EEXIST')throw error;}
 directory(root,uid,true);
 const scope=createHash('sha256').update(JSON.stringify([host.toLowerCase(),port])).digest('hex');
 const file=join(root,scope+'.lock');let fd;
 try{
  fd=fs.openSync(file,fs.constants.O_RDWR|fs.constants.O_CREAT|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK,0o600);
  const stat=fs.fstatSync(fd),named=fs.lstatSync(file);
  if(!stat.isFile()||stat.uid!==uid||(stat.mode&0o077)||stat.nlink!==1||stat.size!==0||
   stat.dev!==named.dev||stat.ino!==named.ino)throw lockUnavailable();
  const deadline=performance.now()+lockTimeout;
  while(true){
   if(signal?.aborted)throw cancelled();
   const remaining=deadline-performance.now();
   if(remaining<=0)throw Error('Private ADB lock timeout');
   let acquired;
   try{acquired=await tryLock(fd,signal,remaining);}
   catch(error){if(!signal?.aborted&&performance.now()>=deadline)throw Error('Private ADB lock timeout');throw error;}
   // A busy event loop or a delayed flock exit can cross the deadline even
   // after acquiring the lock. Drop that FD without starting a transport.
   if(performance.now()>=deadline)throw Error('Private ADB lock timeout');
   if(acquired)return ()=>fs.closeSync(fd);
   try{await delay(Math.min(25,deadline-performance.now()),undefined,{signal});}
   catch(error){if(signal?.aborted)throw cancelled();throw error;}
  }
 }catch(error){if(fd!==undefined)fs.closeSync(fd);throw error;}
 // Never unlink a shared lock file: replacing its inode would allow a second
 // owner while the first still holds the old inode. It contains no metadata.
}
export function packet(name,a=0,b=0,payload=Buffer.alloc(0)) {
 const body=Buffer.isBuffer(payload)?payload:Buffer.from(payload),h=Buffer.alloc(24),code=codes[name];
 if(code===undefined||body.length>1048576)throw Error('Invalid ADB frame');
 h.writeUInt32LE(code,0);h.writeUInt32LE(a,4);h.writeUInt32LE(b,8);h.writeUInt32LE(body.length,12);
 h.writeUInt32LE(body.reduce((n,v)=>(n+v)>>>0,0),16);h.writeUInt32LE((code^0xffffffff)>>>0,20);
 return Buffer.concat([h,body]);
}
export function withRouteAudit(command){
 // BusyBox on UDX710 suppresses rt_proto when printing routes. Append only
 // kernel-verified controller ownership; never infer it from metric alone.
 return /ip -6 route/.test(command)?'ip() { case "$*" in "-6 route add "*|"-6 route del "*) [ -x /tmp/cpe6-maint/route-audit ] || return 1;; esac; /sbin/ip "$@"; rc=$?; case "$*" in "-6 route show "*) [ ! -x /tmp/cpe6-maint/route-audit ] || /tmp/cpe6-maint/route-audit || return 1;; esac; return $rc; }; '+command:command;
}
export async function shell(host,port,command,{timeout=20000,maxBytes=1048576,signal,lockTimeout=timeout,lockDirectory}={}) {
 if(typeof host!=='string'||host.length<1||host.length>255||!Number.isInteger(port)||port<1||port>65535||
  !Number.isInteger(timeout)||timeout<1||timeout>60000||!Number.isInteger(lockTimeout)||lockTimeout<1||lockTimeout>60000)throw Error('Invalid ADB transport options');
 command=withRouteAudit(command);
 const release=await acquire(host,port,{lockTimeout,lockDirectory,signal});
 try{return await transport(host,port,command,{timeout,maxBytes,signal});}
 finally{release();}
}
function transport(host,port,command,{timeout,maxBytes,signal}) {
 return new Promise((resolve,reject)=>{
  if(signal?.aborted){reject(cancelled());return;}
  const socket=new net.Socket(),out=[];let pending=Buffer.alloc(0),remote=0,finished=false,total=0,resultError,closeTimer;
  const abort=()=>{if(finished){resultError=cancelled();socket.destroy();}else end(cancelled());};
  const timer=setTimeout(()=>end(Error('Private ADB timeout')),timeout);
  const end=(err,reply)=>{
   if(finished)return;finished=true;resultError=err;clearTimeout(timer);
   if(err){socket.destroy();return;}
   // Complete CLSE/FIN before opening the next transport. The vendor daemon
   // accepts one host at a time and an immediate destroy can strand its stream.
   closeTimer=setTimeout(()=>socket.destroy(),500);
   socket.end(reply);
  };
  signal?.addEventListener('abort',abort,{once:true});
  socket.on('error',()=>{if(finished)resultError ||= Error('Private ADB unavailable');else end(Error('Private ADB unavailable'));});
  socket.on('close',()=>{
   clearTimeout(timer);clearTimeout(closeTimer);signal?.removeEventListener('abort',abort);
   if(!finished)resultError=Error('Private ADB closed prematurely');
   if(resultError)reject(resultError);else resolve(Buffer.concat(out).toString());
  });
  socket.on('connect',()=>socket.write(packet('CNXN',0x01000000,4096,'host::\0')));
  socket.on('data',chunk=>{
   if(finished)return;
   pending=Buffer.concat([pending,chunk]);
   try {while(pending.length>=24){
    const code=pending.readUInt32LE(0),a=pending.readUInt32LE(4),b=pending.readUInt32LE(8),len=pending.readUInt32LE(12);
    if(len>maxBytes||pending.readUInt32LE(20)!==((code^0xffffffff)>>>0))throw Error('Invalid ADB response');
    if(pending.length<24+len)break;
    const body=pending.subarray(24,24+len),sum=body.reduce((n,v)=>(n+v)>>>0,0);
    if(pending.readUInt32LE(16)!==sum)throw Error('ADB checksum mismatch');
    pending=pending.subarray(24+len);
    if(code===codes.CNXN)socket.write(packet('OPEN',1,0,'shell:'+command+'\0'));
    else if(code===codes.AUTH)throw Error('ADB requires authentication; refusing key provisioning');
    else if(code===codes.OKAY){if(b!==1)throw Error('Wrong ADB stream');remote=a;}
    else if(code===codes.WRTE){if(b!==1)throw Error('Wrong ADB stream');remote=a;total+=len;if(total>maxBytes)throw Error('ADB output exceeds bound');out.push(Buffer.from(body));socket.write(packet('OKAY',1,remote));}
    else if(code===codes.CLSE){if(b!==1)throw Error('Wrong ADB stream');end(null,packet('CLSE',1,a));return;}
    else throw Error('Unexpected ADB command');
   }}catch(e){end(e);}
  });
  if(signal?.aborted)abort();else{try{socket.connect({host,port});}catch(error){end(error);}}
 });
}
