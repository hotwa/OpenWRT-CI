import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {IMAGE,imageRef,mountReady,prepare,ensureImagePin,ensureLocalImage,validateLocalImage,validateConfig,configTemplate,composeTemplate,validateContainer} from '../Scripts/cpe5g-api/model.mjs';
const image=IMAGE;
assert.equal(imageRef(image),image);
for(const bad of ['docker.io/eceasy/cli-proxy-api@sha256:'+'a'.repeat(64),'latest','docker.io/eceasy/cli-proxy-api:8.0.13','docker.io/evil/cpa@sha256:'+'a'.repeat(64),image+';id',image.replace('sha256:','sha512:')]) assert.throws(()=>imageRef(bad));
assert.equal(mountReady('/dev/mmcblk0p8 /data ext4 rw 0 0\n'),true);
assert.equal(mountReady('/dev/mmcblk0p8 /data f2fs rw 0 0\n'),true);
for(const bad of ['overlay /data overlay rw 0 0','tmpfs /data tmpfs rw 0 0','/dev/mmcblk0p8 /database ext4 rw 0 0','/dev/mmcblk0p8 /data vfat rw 0 0']) assert.equal(mountReady(bad),false);
const config=configTemplate('a'.repeat(64),'b'.repeat(64)); validateConfig(config);
const providerConfig=config+`api-keys:
  openai-compatibility:
    - name: primary
      base-url: "https://primary.example/v1"
      api-key-entries:
        - api-key: "local-fixture-primary"
          proxy-url: ""
        - api-key: "local-fixture-backup"
          proxy-url: ""
      models:
        - name: "gpt-*"
          alias: "model-primary"
        - name: "gpt-6"
          alias: "model-alternate"
    - name: backup
      base-url: "https://backup.example/v1"
      api-key-entries:
        - api-key: "local-fixture-secondary"
          proxy-url: ""
      models:
        - name: "gpt-6"
          alias: "model-primary"
`;
validateConfig(providerConfig);
assert.throws(()=>validateConfig(providerConfig.replace('      base-url: "https://primary.example/v1"','      base-url: "https://primary.example/v1"\n      base-url: "https://duplicate.example/v1"')));
assert.throws(()=>validateConfig(providerConfig+'server:\n  host: "0.0.0.0"\n'));
validateConfig(config.replace('"'+'b'.repeat(64)+'"','"$2a$10$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345"'));

for(const bad of [config.replace('127.0.0.1','0.0.0.0'),config.replace('allow-remote: false','allow-remote: true'),config+'server:\n  host: 0.0.0.0\n',config+'host: 0.0.0.0\n',config.replace('secret-key: "'+'b'.repeat(64)+'"','secret-key: ""'),config.replace('    - "'+'a'.repeat(64)+'"','    - ""'),config.replace('    enable: false','    enable: true'),config.replace('  host: "127.0.0.1"','  host: &evil "127.0.0.1"')]) assert.throws(()=>validateConfig(bad));
for(const [before,after] of [['    enabled: false','    enabled: true'],['  trusted-proxies: []','  trusted-proxies: [127.0.0.1]'],['  disable-auto-update-panel: true','  disable-auto-update-panel: false'],['    debug: false','    debug: true'],['    request-log: false','    request-log: true'],['    logs-max-total-size-mb: 8','    logs-max-total-size-mb: 0'],['    error-logs-max-files: 2','    error-logs-max-files: 0']]) assert.throws(()=>validateConfig(config.replace(before,after)));
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'cpe-api-test-'));fs.chmodSync(tmp,0o700);
try {
 const dir=path.join(tmp,'compose','cpe-api');fs.mkdirSync(path.dirname(dir),{mode:0o700});
 const pin=ensureImagePin(dir,image,process.getuid());
 assert.equal(fs.readFileSync(pin,'utf8').trim(),IMAGE);
 assert.equal(ensureImagePin(dir,image,process.getuid()),pin);
 fs.writeFileSync(pin,'docker.io/eceasy/cli-proxy-api@sha256:'+'a'.repeat(64)+'\n');assert.throws(()=>ensureImagePin(dir,image,process.getuid()));assert.ok(fs.readFileSync(pin,'utf8').includes('a'.repeat(64)));fs.writeFileSync(pin,IMAGE+'\n');
 const file=prepare(dir,image,process.getuid());assert.equal(fs.readFileSync(file,'utf8'),composeTemplate(image));
 const first=fs.readFileSync(path.join(dir,'config.yaml'),'utf8'); const keys=fs.readFileSync(path.join(dir,'credentials.json'),'utf8');
 fs.writeFileSync(path.join(dir,'auth','operator-login.json'),'private oauth state',{mode:0o600});prepare(dir,image,process.getuid());
 assert.equal(fs.readFileSync(path.join(dir,'config.yaml'),'utf8'),first);assert.equal(fs.readFileSync(path.join(dir,'credentials.json'),'utf8'),keys);assert.equal(fs.readFileSync(path.join(dir,'auth','operator-login.json'),'utf8'),'private oauth state');
 for(const entry of ['config.yaml','compose.yaml','credentials.json']) assert.equal(fs.statSync(path.join(dir,entry)).mode & 0o777,0o600);
 for(const entry of ['auth','logs']) assert.equal(fs.statSync(path.join(dir,entry)).mode & 0o777,0o700);
 fs.writeFileSync(file,composeTemplate(image).replace('192m','512m'));assert.throws(()=>prepare(dir,image,process.getuid()));fs.writeFileSync(file,composeTemplate(image));
 fs.chmodSync(path.join(dir,'config.yaml'),0o644);assert.throws(()=>prepare(dir,image,process.getuid()));fs.chmodSync(path.join(dir,'config.yaml'),0o600);
 fs.renameSync(path.join(dir,'config.yaml'),path.join(dir,'real-config'));fs.symlinkSync('real-config',path.join(dir,'config.yaml'));assert.throws(()=>prepare(dir,image,process.getuid()));
 const info={Image:image.split('@')[1],Path:'./CLIProxyAPI',Args:['-config','/CLIProxyAPI/config.yaml'],Config:{Image:image,Labels:{'io.hotwa.cpe-api':'8.0.13'}},HostConfig:{NetworkMode:'host',Memory:192*1024*1024,CpuQuota:50000,CpuPeriod:100000,PidsLimit:128,Privileged:false},Mounts:[['config.yaml','/CLIProxyAPI/config.yaml'],['auth','/root/.cli-proxy-api'],['logs','/CLIProxyAPI/logs']].map(([source,Destination])=>({Source:path.join(dir,source),Destination,Type:'bind',RW:true}))};validateContainer(info,image,dir);validateContainer({...info,HostConfig:{...info.HostConfig,CpuQuota:25000,CpuPeriod:50000}},image,dir);validateContainer({...info,HostConfig:{...info.HostConfig,NanoCpus:500000000}},image,dir);assert.throws(()=>validateContainer({...info,Config:{Image:'evil'}},image,dir));
 for(const change of [{Memory:0},{CpuQuota:0},{CpuQuota:100000},{CpuPeriod:0},{CpuPeriod:undefined},{CpuQuota:undefined},{CpuQuota:50000.5},{NanoCpus:0},{PidsLimit:0},{Privileged:true},{CapAdd:['SYS_ADMIN']},{Devices:[{PathOnHost:'/dev/mmcblk0'}]}]) assert.throws(()=>validateContainer({...info,HostConfig:{...info.HostConfig,...change}},image,dir));
 assert.throws(()=>validateContainer({...info,Config:{...info.Config,Cmd:['sh','-c','evil']}},image,dir));
 assert.throws(()=>validateContainer({...info,Path:'sh',Args:['-c','evil']},image,dir));
 assert.throws(()=>validateContainer({...info,Image:'sha256:'+'a'.repeat(64)},image,dir));
 assert.throws(()=>validateContainer({...info,Args:undefined},image,dir));
 validateContainer({...info,Config:{...info.Config,Cmd:['./CLIProxyAPI','-config','/CLIProxyAPI/config.yaml']}},image,dir);
 assert.throws(()=>validateContainer({...info,Config:{...info.Config,Entrypoint:['sh']}},image,dir));
 assert.throws(()=>validateContainer({...info,Mounts:[...info.Mounts,{Source:'/data',Destination:'/data',Type:'bind',RW:true}]},image,dir));
 assert.throws(()=>validateContainer({...info,Mounts:info.Mounts.map((m,i)=>i===0?{...m,RW:false}:m)},image,dir));

 const archive=path.join(tmp,'firmware.oci.tar');fs.writeFileSync(archive,'fixture archive',{mode:0o644});
 validateLocalImage(JSON.stringify([{Architecture:'arm64',Os:'linux',RepoDigests:[image]}]));
 for(const value of [{Architecture:'amd64',Os:'linux',RepoDigests:[image]},{Architecture:'arm64',Os:'linux',RepoDigests:[image.replace(image.split('@')[1],'sha256:'+'a'.repeat(64))]},{Architecture:'arm64',Os:'windows',RepoDigests:[image]}]) assert.throws(()=>validateLocalImage(JSON.stringify([value])));
 const wrongTarget=[];assert.throws(()=>ensureLocalImage(argv=>{wrongTarget.push(argv[0]);return JSON.stringify([{Architecture:'arm64',Os:'linux',RepoDigests:['evil']}]);},archive,process.getuid()));assert.deepEqual(wrongTarget,['image']);
 let present=false;const operations=[];
 const run=(argv,options)=>{operations.push({argv,options});if(argv[0]==='image' && !present) throw Error('not found');if(argv[0]==='load') present=true;return JSON.stringify([{Architecture:'arm64',Os:'linux',RepoDigests:[image]}]);};
 ensureLocalImage(run,archive,process.getuid());assert.deepEqual(operations.map(x=>x.argv[0]),['image','info','load','image']);assert.equal(operations[2].options.timeout,120000);
 operations.length=0;ensureLocalImage(run,archive,process.getuid());assert.deepEqual(operations.map(x=>x.argv[0]),['image']);
 present=false;operations.length=0;assert.throws(()=>ensureLocalImage(run,path.join(tmp,'missing'),process.getuid()));assert.ok(!operations.some(x=>x.argv[0]==='load'));
 fs.chmodSync(archive,0o666);assert.throws(()=>ensureLocalImage(run,archive,process.getuid()));fs.chmodSync(archive,0o644);
 fs.symlinkSync(archive,path.join(tmp,'symlink.oci.tar'));assert.throws(()=>ensureLocalImage(run,path.join(tmp,'symlink.oci.tar'),process.getuid()));
 assert.throws(()=>ensureLocalImage(argv=>{if(argv[0]==='image')throw Error('missing');if(argv[0]==='info')throw Error('runtime down');throw Error('load must not happen');},archive,process.getuid()));
} finally {fs.rmSync(tmp,{recursive:true,force:true});}
console.log('CPE API model: pinned image, mount, auth, config preservation and safety guards passed');
