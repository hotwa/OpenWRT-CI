// Minimal legacy ADB transport for the private, physically attached UDX710.
// Authentication-required daemons fail closed; this never provisions a key.
import net from 'node:net';
const codes = Object.fromEntries(['CNXN','AUTH','OPEN','OKAY','WRTE','CLSE'].map(s=>[s,Buffer.from(s).readUInt32LE()]));
export function packet(name,a=0,b=0,payload=Buffer.alloc(0)) {
 const body=Buffer.isBuffer(payload)?payload:Buffer.from(payload),h=Buffer.alloc(24),code=codes[name];
 if(code===undefined||body.length>1048576)throw Error('Invalid ADB frame');
 h.writeUInt32LE(code,0);h.writeUInt32LE(a,4);h.writeUInt32LE(b,8);h.writeUInt32LE(body.length,12);
 h.writeUInt32LE(body.reduce((n,v)=>(n+v)>>>0,0),16);h.writeUInt32LE((code^0xffffffff)>>>0,20);
 return Buffer.concat([h,body]);
}
export function shell(host,port,command,{timeout=20000,maxBytes=1048576,signal}={}) {
 return new Promise((resolve,reject)=>{
  const cancelled=()=>Object.assign(Error('Private ADB cancelled'),{name:'AbortError'});
  if(signal?.aborted){reject(cancelled());return;}
  const socket=net.createConnection({host,port}),out=[];let pending=Buffer.alloc(0),remote=0,finished=false,total=0;
  const abort=()=>end(cancelled());
  const detach=()=>signal?.removeEventListener('abort',abort);
  const end=(err,reply)=>{
   if(finished)return;finished=true;
   if(err){detach();socket.destroy();reject(err);return;}
   // Complete CLSE/FIN before opening the next transport. The vendor daemon
   // accepts one host at a time and an immediate destroy can strand its stream.
   const timer=setTimeout(()=>socket.destroy(),500);
   socket.once('close',()=>{clearTimeout(timer);detach();resolve(Buffer.concat(out).toString());});
   socket.end(reply);
  };
  signal?.addEventListener('abort',abort,{once:true});
  socket.setTimeout(timeout,()=>end(Error('Private ADB timeout')));
  socket.on('error',()=>end(Error('Private ADB unavailable')));
  socket.on('close',()=>{if(!finished)end(Error('Private ADB closed prematurely'));});
  socket.on('connect',()=>socket.write(packet('CNXN',0x01000000,4096,'host::\0')));
  socket.on('data',chunk=>{
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
    else if(code===codes.CLSE){if(b!==1)throw Error('Wrong ADB stream');end(null,packet('CLSE',1,a));}
    else throw Error('Unexpected ADB command');
   }}catch(e){end(e);}
  });
 });
}
