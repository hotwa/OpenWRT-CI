import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
export const HOME='/data/compose/cpe-api';
export const NAME='cpe-api';
export const ROM_IMAGE_ARCHIVE='/usr/share/cpe-api/cli-proxy-api-v8.0.13-arm64.oci.tar';
export const IMAGE='docker.io/eceasy/cli-proxy-api@sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d';
export function imageRef(value) {
 if (!/^docker\.io\/eceasy\/cli-proxy-api@sha256:[a-f0-9]{64}$/.test(value) || value!==IMAGE) throw Error('invalid pinned official image');
 return value;
}
export function mountReady(mounts) {
 return mounts.split('\n').some(line=>/^\/dev\/\S+ \/data (ext4|f2fs) /.test(line));
}
function secureDirectory(dir,ownerUid=0) {
 if (fs.existsSync(dir)) { const s=fs.lstatSync(dir); if(!s.isDirectory() || s.isSymbolicLink() || s.uid!==ownerUid) throw Error('unsafe application directory'); }
 else fs.mkdirSync(dir,{mode:0o700});
 fs.chmodSync(dir,0o700);
}
function privateFile(file,ownerUid=0) {
 const s=fs.lstatSync(file);
 if (!s.isFile() || s.isSymbolicLink() || s.uid!==ownerUid || (s.mode & 0o077)!==0 || s.nlink!==1) throw Error('unsafe application file');
}
function writeNew(file,value) {fs.writeFileSync(file,value,{flag:'wx',mode:0o600});}
export function configTemplate(client,management) {
 return `config-version: 8\nserver:\n  host: "127.0.0.1"\n  port: 8317\n  trusted-proxies: []\n  discovery:\n    enabled: false\nmanagement:\n  allow-remote: false\n  secret-key: "${management}"\n  disable-control-panel: true\n  disable-auto-update-panel: true\naccess:\n  api-keys:\n    - "${client}"\noauth:\n  auth-dir: "/root/.cli-proxy-api"\n  auth-auto-refresh-workers: 2\nrequests:\n  streaming:\n    keepalive-seconds: 15\nobservability:\n  logs:\n    debug: false\n    logging-to-file: true\n    logs-max-total-size-mb: 8\n    error-logs-max-files: 2\n    request-log: false\n  usage:\n    usage-statistics-enabled: false\n  pprof:\n    enable: false\n    addr: "127.0.0.1:8316"\nplugins:\n  enabled: false\n`;
}
// Deliberately limited YAML grammar: scalar maps and normal block lists.
// Each list item has its own path, so provider name/base-url/model fields may
// repeat across items, while duplicate fields within one mapping still fail.
function scalar(raw) {
 const value=raw.trim();
 if (/^[&*!>|]|[{}]/.test(value)) throw Error('unsupported YAML scalar');
 if(value.startsWith('"')) {try {return JSON.parse(value);} catch {throw Error('unsupported quoted scalar');}}
 if(value.startsWith("'")) {if(!value.endsWith("'")) throw Error('unsupported quoted scalar'); return value.slice(1,-1).replace(/''/g,"'");}
 return value.replace(/ +#.*$/,'').trim();
}
export function validateConfig(text) {
 if (/[\t\r]|^[ ]*(---|\.\.\.)/m.test(text)) throw Error('unsupported YAML configuration');
 const values=new Map(),stack=[],listIndexes=new Map();
 function put(key,value) {if(values.has(key)) throw Error('duplicate YAML path'); values.set(key,value);}
 for(const line of text.split('\n')) {
  if(/^\s*(#.*)?$/.test(line)) continue;
  const prefix=/^( *)(.*)$/.exec(line); let indent=prefix[1].length,body=prefix[2];
  while(stack.length && stack.at(-1).indent>=indent) stack.pop();
  if(body.startsWith('- ')) {
   if(!stack.length) throw Error('root sequence refused');
   const parent=stack.map(x=>x.key).join('.');
   const index=listIndexes.get(parent)??0;listIndexes.set(parent,index+1);
   stack.push({indent,key:String(index)});body=body.slice(2);indent+=2;
   if(!/^[A-Za-z_][A-Za-z0-9_-]*:($| )/.test(body)) {
    put(stack.map(x=>x.key).join('.'),scalar(body));continue;
   }
  }
  const match=/^([A-Za-z_][A-Za-z0-9_-]*):(?: (.*))?$/.exec(body);
  if(!match) throw Error('unsupported YAML mapping');
  const key=[...stack.map(x=>x.key),match[1]].join('.'),value=scalar(match[2]??'');
  put(key,value);if(!value) stack.push({indent,key:match[1]});
 }
 for(const [k,v] of Object.entries({'config-version':'8','server.host':'127.0.0.1','server.port':'8317','management.allow-remote':'false','management.disable-control-panel':'true','management.disable-auto-update-panel':'true','server.discovery.enabled':'false','server.trusted-proxies':'[]','oauth.auth-dir':'/root/.cli-proxy-api','observability.pprof.enable':'false','observability.logs.debug':'false','observability.logs.request-log':'false','observability.logs.logging-to-file':'true','observability.logs.logs-max-total-size-mb':'8','observability.logs.error-logs-max-files':'2','plugins.enabled':'false'})) {
  if(values.get(k)!==v) throw Error('application safety configuration differs');
 }
 for(const k of ['host','port','remote-management','auth-dir','pprof']) if(values.has(k)) throw Error('legacy security field refused');
 if(values.has('api-keys') && (values.get('api-keys')!=='' || [...values.keys()].some(key=>/^api-keys\.[0-9]+($|\.)/.test(key)))) throw Error('legacy client keys refused');
 const keys=[...values].filter(([key])=>/^access\.api-keys\.[0-9]+$/.test(key)).map(([,value])=>value);
 if(!values.get('management.secret-key') || !keys.length || keys.some(key=>!/^[-A-Za-z0-9_]{32,}$/.test(key))) throw Error('client or management authentication missing');
}
export function composeTemplate(image) {
 imageRef(image);
 return `services:\n  api:\n    image: ${image}\n    container_name: ${NAME}\n    network_mode: host\n    labels:\n      io.hotwa.cpe-api: "8.0.13"\n    restart: always\n    mem_limit: 192m\n    cpus: 0.5\n    pids_limit: 128\n    command: ["./CLIProxyAPI", "-config", "/CLIProxyAPI/config.yaml"]\n    volumes:\n      - ./config.yaml:/CLIProxyAPI/config.yaml\n      - ./auth:/root/.cli-proxy-api\n      - ./logs:/CLIProxyAPI/logs\n`;
}
export function prepare(dir,image,ownerUid=0) {
 imageRef(image);
 // Parents too: do not traverse a retained symlink to arbitrary paths.
 secureDirectory(path.dirname(dir),ownerUid); secureDirectory(dir,ownerUid);
 for(const name of ['auth','logs']) secureDirectory(path.join(dir,name),ownerUid);
 const config=path.join(dir,'config.yaml'), credentials=path.join(dir,'credentials.json');
 if (!fs.existsSync(config)) {
  // An old credentials file must be checked/reused, never silently replaced.
  if(!fs.existsSync(credentials)) writeNew(credentials,JSON.stringify({clientKey:crypto.randomBytes(32).toString('hex'),managementKey:crypto.randomBytes(32).toString('hex')})+'\n');
  privateFile(credentials,ownerUid); const keys=JSON.parse(fs.readFileSync(credentials,'utf8'));
  if(!/^[a-f0-9]{64}$/.test(keys.clientKey) || !/^[a-f0-9]{64}$/.test(keys.managementKey)) throw Error('invalid stored credentials');
  writeNew(config,configTemplate(keys.clientKey,keys.managementKey));
 }
 privateFile(config,ownerUid); validateConfig(fs.readFileSync(config,'utf8'));
 if(fs.existsSync(credentials)) privateFile(credentials,ownerUid);
 const compose=path.join(dir,'compose.yaml'), expected=composeTemplate(image);
 if(!fs.existsSync(compose)) writeNew(compose,expected);
 privateFile(compose,ownerUid);
 if(fs.readFileSync(compose,'utf8')!==expected) throw Error('existing compose differs; explicit deployment migration required');
 return compose;
}
export function ensureImagePin(dir,image=IMAGE,ownerUid=0) {
 imageRef(image);secureDirectory(path.dirname(dir),ownerUid);secureDirectory(dir,ownerUid);
 const pin=path.join(dir,'image');
 if(!fs.existsSync(pin)) writeNew(pin,image+'\n');
 privateFile(pin,ownerUid);
 if(fs.readFileSync(pin,'utf8').trim()!==image) throw Error('existing image differs; explicit migration required');
 return pin;
}
export function validateContainer(info,image,dir) {
 const host=info?.HostConfig,config=info?.Config;
 const command=['./CLIProxyAPI','-config','/CLIProxyAPI/config.yaml'];
 if(info?.Image!==image.split('@')[1] || config?.Image!==image || config?.Labels?.['io.hotwa.cpe-api']!=='8.0.13' || host?.NetworkMode!=='host' || !Array.isArray(info?.Args) || JSON.stringify([info.Path,...info.Args])!==JSON.stringify(command)) throw Error('existing container execution differs');
 if(config.Cmd!=null && (!Array.isArray(config.Cmd) || (config.Cmd.length && JSON.stringify(config.Cmd)!==JSON.stringify(command)))) throw Error('existing command metadata differs');
 if(config.Entrypoint!=null && (!Array.isArray(config.Entrypoint) || config.Entrypoint.length)) throw Error('existing entrypoint differs');
 const cpuFields=['NanoCpus','NanoCPUs','CgroupNanoCpus'].filter(key=>host[key]!==undefined);
 if(host.Memory!==192*1024*1024 || !Number.isSafeInteger(host.CpuPeriod) || host.CpuPeriod<=0 || !Number.isSafeInteger(host.CpuQuota) || host.CpuQuota<=0 || host.CpuQuota*2!==host.CpuPeriod || cpuFields.some(key=>host[key]!==500000000) || host.PidsLimit!==128) throw Error('existing resource limits differ');
 if(host.Privileged!==false || [host.CapAdd,host.Devices].some(value=>value!=null && (!Array.isArray(value) || value.length))) throw Error('existing container security differs');
 if(!Array.isArray(info.Mounts) || info.Mounts.length!==3) throw Error('existing container mount count differs');
 for(const [source,destination] of [['config.yaml','/CLIProxyAPI/config.yaml'],['auth','/root/.cli-proxy-api'],['logs','/CLIProxyAPI/logs']]) {
  if(!info.Mounts.some(m=>m.Type==='bind' && m.RW===true && m.Source===path.join(dir,source) && m.Destination===destination)) throw Error('existing container mounts differ');
 }
}
export function validateLocalImage(output) {
 const info=JSON.parse(output)?.[0];
 // Image Id is the config digest; RepoDigests records the actual manifest target.
 const accepted=[IMAGE,IMAGE.replace('docker.io/','')];
 if(info?.Architecture!=='arm64' || info?.Os!=='linux' || !info.RepoDigests?.some(ref=>accepted.includes(ref))) throw Error('local image target differs');
}
export function ensureLocalImage(run,archive=ROM_IMAGE_ARCHIVE,ownerUid=0) {
 let output;
 try {output=run(['image','inspect',IMAGE]);} catch { /* Never pull on a miss. */ }
 if(output!==undefined) {validateLocalImage(output);return;}
 // Runtime must be healthy before considering a local, fixed firmware archive.
 run(['info']);
 const source=fs.lstatSync(archive);
 if(!source.isFile() || source.isSymbolicLink() || source.uid!==ownerUid || source.nlink!==1 || (source.mode & 0o022)!==0) throw Error('unsafe ROM image archive');
 run(['load','--input',archive],{timeout:120000});
 validateLocalImage(run(['image','inspect',IMAGE]));
}
function nerd(args,options={}) {const result=spawnSync('/usr/bin/nerdctl',['--address','/run/containerd/containerd.sock','--namespace','default',...args],{stdio:'pipe',timeout:20000,...options}); if(result.status!==0) throw Error('container runtime operation failed'); return result.stdout?.toString()??'';}
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function main(args) {
 if(!mountReady(fs.readFileSync('/proc/mounts','utf8'))) throw Error('real /data block mount required');
 const command=args[0];
 if(args.length>2) throw Error('unexpected arguments');
 if(command==='boot') {const setting=spawnSync('/sbin/uci',['-q','get','cpe_api.main.enabled'],{stdio:'pipe',timeout:5000});if(setting.status!==0 || setting.stdout.toString().trim()!=='1') return;}
 if(command==='stop' || command==='disable') { spawnSync('/sbin/uci',['set','cpe_api.main.enabled=0'],{stdio:'ignore'}); spawnSync('/sbin/uci',['commit','cpe_api'],{stdio:'ignore'}); secureDirectory('/data/compose'); secureDirectory(HOME); const marker=path.join(HOME,'disabled'); if(!fs.existsSync(marker)) writeNew(marker,'operator stop\n'); nerd(['stop',NAME]); return; }
 if(!['boot','start','prepare','status'].includes(command)) throw Error('usage: cpe-api <boot|start|prepare|stop|disable|status> [pinned-image]');
 if(command==='status') { console.log(JSON.stringify({service:NAME,disabled:fs.existsSync(path.join(HOME,'disabled')),configured:fs.existsSync(path.join(HOME,'config.yaml'))})); return; }
 const pin=path.join(HOME,'image');
 if(args[1] && command!=='prepare') throw Error('image changes require explicit prepare');
 if(command==='boot' && fs.existsSync(path.join(HOME,'disabled'))) return;
 ensureImagePin(HOME,args[1]??IMAGE);
 if(command==='boot') { for(let n=0;n<12 && !fs.existsSync('/run/containerd/containerd.sock');n++) await sleep(5000); }
 privateFile(pin); const image=imageRef(fs.readFileSync(pin,'utf8').trim()),compose=prepare(HOME,image);
 if(command==='prepare') return;
 ensureLocalImage(nerd); // A fixed ROM archive is the only offline fallback.
 if(command==='start') { const marker=path.join(HOME,'disabled'); if(fs.existsSync(marker)) {privateFile(marker);fs.unlinkSync(marker);} spawnSync('/sbin/uci',['set','cpe_api.main.enabled=1'],{stdio:'ignore'}); spawnSync('/sbin/uci',['commit','cpe_api'],{stdio:'ignore'}); }
 const existing=nerd(['ps','-a','--format','{{.Names}}']).split('\n').includes(NAME);
 if(existing) {
  const info=JSON.parse(nerd(['inspect',NAME]))[0];
  validateContainer(info,image,HOME);
  // Preserve containerd's persisted stopped state at boot.
  if(command==='start') nerd(['start',NAME]);
  return;
 }
 nerd(['compose','--file',compose,'up','--pull','never','-d'],{cwd:HOME});
}
if(process.argv[1]===fileURLToPath(import.meta.url)) main(process.argv.slice(2)).catch(()=>{console.error('cpe-api: deferred or refused; check local image, mount and protected configuration');process.exitCode=1;});
