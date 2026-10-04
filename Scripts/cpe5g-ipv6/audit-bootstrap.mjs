// Keep the read-only companion in modem RAM. No UDX firmware writes, no SIM
// dialing/reset, no persistent credentials or public/LAN HTTP listener.
import fs from 'node:fs';
import http from 'node:http';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {setTimeout as wait} from 'node:timers/promises';
import {shell} from './adb.mjs';
import {ensureLogger} from './quota-logger.mjs';
import {reconcile} from './local-failover.mjs';
export const remotePath='/tmp/cpe6-maint/route-audit';
export const firmwarePath='/usr/libexec/cpe5g-ipv6/route-audit';
export const hashOf=b=>createHash('sha256').update(b).digest('hex');
export function verifiedHash(output,expected){return output.trim().split(/\s+/)[0]===expected;}
export async function provision({body,transport=shell,signal,nft=args=>execFileSync('nft',args,{encoding:'utf8',timeout:3000}),listenAddress='192.168.66.2',port=18999}={}){
 const hash=hashOf(body),host='192.168.66.1';
 const call=cmd=>transport(host,5555,cmd,{timeout:12000,signal});
 if(verifiedHash(await call(`sha256sum ${remotePath} 2>/dev/null`),hash))return false;
 let server,handle;
 try{
  server=http.createServer((q,r)=>{
   if(q.socket.remoteAddress!==host||q.url!=='/route-audit'){r.writeHead(404);r.end();return;}
   r.end(body);
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,listenAddress,resolve);});
  nft(['insert','rule','inet','fw4','input','iifname','usb0','ip','saddr',host,'tcp','dport',String(port),'accept','comment','cpe6-audit-bootstrap']);
  handle=nft(['-a','list','chain','inet','fw4','input']).split('\n').find(x=>x.includes('comment "cpe6-audit-bootstrap"'))?.match(/handle (\d+)/)?.[1];
  if(!handle)throw Error('bootstrap rule handle unavailable');
  const output=await call(`umask 077; mkdir -p /tmp/cpe6-maint; wget -q -T 8 -O ${remotePath}.new http://${listenAddress}:${port}/route-audit && sha256sum ${remotePath}.new`);
  if(!verifiedHash(output,hash))throw Error('companion checksum mismatch');
  if(!(await call(`chmod 700 ${remotePath}.new && mv ${remotePath}.new ${remotePath} && printf CPE6_AUDIT_READY`)).includes('CPE6_AUDIT_READY'))throw Error('companion publish failed');
  return true;
 }finally{
  try{if(handle)nft(['delete','rule','inet','fw4','input','handle',handle]);}
  finally{if(server){server.closeAllConnections();await new Promise(r=>server.close(r));}}
 }
}
export async function main(){
 if(fs.readFileSync('/tmp/sysinfo/board_name','utf8').trim()!=='jdcloud,re-ss-01')throw Error('CPE board mismatch');
 const body=fs.readFileSync(firmwarePath),abort=new AbortController();
 const stop=()=>abort.abort();for(const s of ['SIGTERM','SIGINT','SIGHUP'])process.on(s,stop);
 let nextMaintenance=0;
 try{
  while(!abort.signal.aborted){
   try{reconcile();}catch(e){console.error('CPE local IPv4 reconciliation deferred:',e.message);}
   if(Date.now()>=nextMaintenance){
   nextMaintenance=Date.now()+30000;
   try{await ensureLogger({signal:abort.signal});}catch(e){if(!abort.signal.aborted)console.error('CPE quota logger recovery deferred:',e.message);}
   try{if(await provision({body,signal:abort.signal}))console.log('CPE route audit provisioned');}
   catch(e){if(!abort.signal.aborted)console.error('CPE route audit provisioning deferred:',e.message);}
   }
   try{await wait(5000,undefined,{signal:abort.signal});}catch{}
  }
 }finally{for(const s of ['SIGTERM','SIGINT','SIGHUP'])process.removeListener(s,stop);}
}
if(import.meta.url===`file://${process.argv[1]}`)main().catch(e=>{console.error('cpe6-route-audit:',e.message);process.exitCode=1;});
