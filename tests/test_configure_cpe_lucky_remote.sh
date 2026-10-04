#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$ROOT_DIR" <<'PY'
import ast, base64, copy, gzip, io, json, os, random, shutil
from pathlib import Path
import stat, subprocess, sys, tarfile, tempfile
root=Path(sys.argv[1]); script=root/'Scripts/ConfigureCpeLuckyRemote.sh'; guard=root/'Scripts/PrivateFirmwareGuard.sh'
sh_binary=shutil.which('sh');node_binary=shutil.which('node')
assert sh_binary and node_binary,'shell and Node runtime required for injector fixtures'
names=['CPE_LUCKY_REMOTE_BUNDLE_'+str(i) for i in range(1,7)]
flags={'WRT_CPE_5G':'true','WRT_CPE_IPV6':'true','WRT_REQUIRED_DEVICE':'jdcloud_re-ss-01','WRT_ENCRYPT_ARTIFACT':'true'}
environment={k:v for k,v in os.environ.items() if k not in names and k not in flags};environment.update(flags)
paths=[
 'etc/lucky/lucky_base.lkcf','etc/lucky/lucky_ddns.lkcf','etc/lucky/lucky_reverseproxy.lkcf','etc/lucky/lucky_ssl.lkcf','etc/lucky/lucky_ipfilter.lkcf',
 'etc/lucky/cert-sync/lucky.token','etc/lucky/cert-sync/cpe5g-origin/current/fullchain.pem','etc/lucky/cert-sync/cpe5g-origin/current/privkey.pem',
 'etc/lucky/cert-sync/cpe5g-origin/current/certificate-pin.json',
 'etc/cpe5g/public-origin.json','etc/cpe5g-lucky/public-management.json','etc/cpe5g-lucky/managed-native.json','etc/cpe5g-lucky/tls/client-ca.pem',
 'etc/cpe5g-lucky/tls/health-client.crt','etc/cpe5g-lucky/tls/health-client.key']
origin={'enabled':True,'hostname':'cpe.lucky.jmsu.top','source_policy':'mtls','client_ca_sha256':'a'*64,'allowed_sources':[]}
pin_path='etc/lucky/cert-sync/cpe5g-origin/current/certificate-pin.json'
certificate_pin={'version':1,'hostname':'cpe.lucky.jmsu.top','origin_sni':'cpe-origin.jmsu.top','server_cert_sha256':'b'*64}
manifest_path='etc/cpe5g-lucky/public-management.json';managed_path='etc/cpe5g-lucky/managed-native.json'
manifest={'version':1,'hostname':'cpe.lucky.jmsu.top','origin_sni':'cpe-origin.jmsu.top',
 'lucky_rule_key':'fixtureRule','ddns_task_key':'fixtureDdns','ssl_task_key':'fixtureSsl',
 'origin_header_secret':'c'*64,'username':'cpe-temp','password':'FixtureOnlyRandomLikePasswordValue123'}
managed={'version':1,'domain_suffix':'jmsu.top',
 'rule':{'RuleKey':manifest['lucky_rule_key'],'RuleName':'managed-cpe-udx-public-backend','Enable':True,'Network':'tcp4',
  'ListenIP':'127.0.0.1','ListenPort':16801,'EnableTLS':False,'Http3':False,
  'DefaultProxy':{'WebServiceType':'close','Locations':[]},
  'ProxyList':[{'Key':'fixtureChild','Enable':True,'WebServiceType':'reverseproxy','Domains':[manifest['hostname']],
   'Locations':['http://192.168.66.1:6677'],'EnableBasicAuth':True,'WebAuth':True,
   'BasicAuthUserList':manifest['username']+':'+manifest['password'],'CacheEnabled':False,
   'OtherParams':{'WebAuth':True,'BasicAuthRegConf':'','AutoOptionsFirewall':False,'HttpClientProxyType':'','HttpClientProxyAddr':''}}]},
 'ddns':{'TaskKey':manifest['ddns_task_key'],'TaskName':'managed-cpe5g-origin-ipv6','TaskType':'IPv6','Enable':True,
  'V4QueryIPEnable':False,'V6QueryIPEnable':True,'V6QueryIPType':'command','V6GetIPScript':'/usr/libexec/cpe5g-ipv6/select-origin-ipv6',
  'DNS':{'Name':'alidns','ID':'FixtureDedicatedDNSID','Secret':'FixtureDedicatedDNSSecret','CallAPINetwork':'tcp4','HttpClientProxyType':''},
  'Records':[{'Disable':False,'SyncRecordData':{'type':'AAAA','fullDomainName':manifest['origin_sni'],'ipv6Address':'{ipv6Addr}'}}],
  'WebhookEnable':False,'GlobalWebhook':False},
 'ssl':{'Key':manifest['ssl_task_key'],'Remark':'cpe5g-origin','Enable':True,'AddFrom':'acme','MappingToPath':True,
  'MappingPath':'/etc/lucky/cert-sync/cpe5g-acme','MappingChangeScript':'/usr/libexec/cpe5g-ipv6/deploy-origin-certificate',
  'AllSyncClient':False,'SyncClientList':[],'ExtParams':{'acmeDNSServer':'alidns','acmeDomains':[manifest['origin_sni']],
   'acmeDNSID':'FixtureDedicatedDNSID','acmeDNSSecret':'FixtureDedicatedDNSSecret',
   'acmeCADirURL':'https://acme-v02.api.letsencrypt.org/directory','acmeProxy':''}}}
files={n:b'fixture-only-placeholder-not-a-real-credential' for n in paths}
files['etc/cpe5g/public-origin.json']=json.dumps(origin).encode()
files[pin_path]=json.dumps(certificate_pin).encode()
files[manifest_path]=json.dumps(manifest).encode();files[managed_path]=json.dumps(managed).encode()
api_path='etc/cpe5g-lucky/api-service.json'
api={'version':1,'enabled':True,'publicHost':'ai.lucky.jmsu.top','upstream':'http://127.0.0.1:8317',
 'listen':'127.0.0.1:16802','authentication':'upstream-bearer','originSecretRef':'public-management.json#origin_header_secret',
 'allowedRequests':[{'method':'GET','path':'/v1/models'},{'method':'POST','path':'/v1/chat/completions'},{'method':'POST','path':'/v1/responses'}],
 'nativeRuleKey':'cpe5g-api-public','nativeChildKey':'cpe5g-api-public-child'}
assert len(paths)==15
cases=0
def package(selected,extras=(),pax=False,dirs=False):
 out=io.BytesIO()
 with tarfile.open(fileobj=out,mode='w',format=tarfile.PAX_FORMAT if pax else tarfile.USTAR_FORMAT) as a:
  if dirs:
   for name in ('etc','etc/lucky','etc/lucky/cert-sync'):
    member=tarfile.TarInfo(name);member.type=tarfile.DIRTYPE;a.addfile(member)
  for name,payload in selected.items():
   member=tarfile.TarInfo(name);member.size=len(payload)
   if pax:member.mtime=0.5
   a.addfile(member,io.BytesIO(payload))
  for member,payload in extras:a.addfile(member,io.BytesIO(payload) if payload else None)
 return base64.b64encode(gzip.compress(out.getvalue(),mtime=0)).decode()
def snapshot(folder):
 result={}
 for path in sorted(folder.rglob('*')):
  mode=path.lstat().st_mode
  result[str(path.relative_to(folder))]=(stat.S_IMODE(mode),os.readlink(path) if path.is_symlink() else path.read_bytes() if stat.S_ISREG(mode) else None)
 return result
def invoke(folder,payload='',chunks=None,changed=None,enable='true'):
 global cases
 env=environment.copy();env.update(chunks if chunks is not None else ({names[0]:payload} if payload else {}))
 for k,v in (changed or {}).items():
  if v is None:env.pop(k,None)
  else:env[k]=v
 r=subprocess.run([sh_binary,str(script),str(folder),enable],env=env,stdin=subprocess.DEVNULL,capture_output=True,timeout=15)
 for private in ('fixture-only-placeholder',manifest['password'],managed['ddns']['DNS']['ID'],managed['ddns']['DNS']['Secret']):
  assert private.encode() not in r.stdout+r.stderr,'seed leaked'
 cases+=1;return r
def reject(folder,payload='',**kw):
 before=snapshot(folder);r=invoke(folder,payload,**kw)
 assert r.returncode!=0,'invalid seed accepted'
 assert snapshot(folder)==before,'rejected seed changed overlay'
with tempfile.TemporaryDirectory(prefix='cpe-lucky-seed-test-') as raw:
 base=Path(raw);target=base/'overlay';target.mkdir();(target/'sentinel').write_text('keep')
 before=snapshot(target)
 assert invoke(target,enable='false',changed={n:None for n in flags}).returncode==0 and snapshot(target)==before
 encoded=package(files,pax=True,dirs=True)
 r=invoke(target,encoded);assert r.returncode==0,'valid seed rejected'
 for name,payload in files.items():
  path=target/name;assert path.read_bytes()==payload and stat.S_IMODE(path.stat().st_mode)==0o600
  for parent in path.parents:
   if parent==target/'etc':break
   assert stat.S_IMODE(parent.stat().st_mode)==0o700
 assert (target/'sentinel').read_text()=='keep' and not any(p.name.startswith('.cpe-lucky-seed-') for p in target.iterdir())
 extra=target/'etc/lucky/unmanaged.fixture';extra.write_text('preserve')
 (target/paths[0]).write_text('old');(target/paths[0]).chmod(0o644);(target/'etc/lucky').chmod(0o755)
 assert invoke(target,encoded).returncode==0 and extra.read_text()=='preserve' and (target/paths[0]).read_bytes()==files[paths[0]]
 assert stat.S_IMODE((target/'etc/lucky').stat().st_mode)==0o700
 for count in (3,4,5,6):
  step=(len(encoded)+count-1)//count
  chunks={names[i]:encoded[i*step:(i+1)*step] for i in range(count)}
  assert all(chunks.values()) and invoke(target,chunks=chunks).returncode==0
 # Realistic incompressible fixture validates the exact 35,000 ASCII boundary
 # and a five-slot package without accessing any real private material.
 large=files.copy();noise=random.Random(710)
 for name,length in ((paths[0],60000),(paths[1],60000),(paths[2],4000)):
  large[name]=noise.randbytes(length)
 large_encoded=package(large)
 assert 140000<len(large_encoded)<=175000
 large_chunks={names[i]:large_encoded[i*35000:(i+1)*35000] for i in range(5)}
 assert all(large_chunks.values()) and len(large_chunks[names[0]])==35000
 assert invoke(target,chunks=large_chunks).returncode==0
 assert all((target/name).read_bytes()==payload for name,payload in large.items())
 required={k:v for k,v in files.items() if not k.endswith('lucky_ipfilter.lkcf')}
 assert len(required)==14
 assert invoke(target,package(required)).returncode==0
 # Legacy policy pin remains optional; certificate-owned pin is required either way.
 assert invoke(target,package({**files,'etc/cpe5g/public-origin.json':json.dumps({**origin,'server_cert_sha256':'c'*64}).encode()})).returncode==0
 bad=base/'bad';bad.mkdir();(bad/'sentinel').write_text('keep')
 for name in flags:
  reject(bad,encoded,changed={name:None});reject(bad,encoded,changed={name:'false'})
 for enable in ('false','invalid'):reject(bad,encoded,enable=enable)
 for chunks in ({names[1]:encoded},{names[0]:encoded[:10],names[2]:encoded[10:]},
   {names[5]:encoded},{names[0]:encoded[:10],names[5]:encoded[10:]},
   {names[0]:'A'*35001},{names[0]:'not strict base64!'},{names[0]:'non-ascii-'+chr(233)}):
  reject(bad,chunks=chunks)
 reject(bad,base64.b64encode(b'not-gzip').decode())
 reject(bad,base64.b64encode(gzip.compress(b'X'*(256*1024+1),mtime=0)).decode())
 for name in required:reject(bad,package({k:v for k,v in files.items() if k!=name}))
 reject(bad,package({**files,'etc/lucky/cert-sync/lucky.token':b''}))
 reject(bad,package({**files,paths[0]:b'x'*(64*1024+1)}))
 for name in ('../escape','/absolute','etc/lucky/../../escape','./etc/lucky/lucky_base.lkcf','unexpected'):
  reject(bad,package({**files,name:b'fixture'}))
 duplicate=tarfile.TarInfo(paths[0]);duplicate.size=7
 reject(bad,package(files,[(duplicate,b'fixture')]))
 for kind in (tarfile.SYMTYPE,tarfile.LNKTYPE,tarfile.FIFOTYPE,tarfile.CHRTYPE,tarfile.BLKTYPE):
  member=tarfile.TarInfo('etc/lucky/lucky_ipfilter.lkcf');member.type=kind;member.linkname='fixture-target'
  reject(bad,package(required,[(member,b'')]))
 raw_tar=gzip.decompress(base64.b64decode(encoded))
 reject(bad,base64.b64encode(gzip.compress(raw_tar+b'fixture-trailing-data',mtime=0)).decode())
 for field,value in (('enabled',False),('hostname','wrong.example.invalid'),('source_policy','allowlist'),('client_ca_sha256','z'*64),('server_cert_sha256','short'),('allowed_sources',['2001:db8::/64'])):
  reject(bad,package({**files,'etc/cpe5g/public-origin.json':json.dumps({**origin,field:value}).encode()}))
 for field,value in (('version',True),('version',1.0),('version',2),('hostname','wrong.example.invalid'),('origin_sni','wrong.example.invalid'),('server_cert_sha256','short'),('server_cert_sha256','z'*64),('server_cert_sha256',None)):
  reject(bad,package({**files,pin_path:json.dumps({**certificate_pin,field:value}).encode()}))
 for field in certificate_pin:
  reject(bad,package({**files,pin_path:json.dumps({k:v for k,v in certificate_pin.items() if k!=field}).encode()}))
 reject(bad,package({**files,pin_path:json.dumps({**certificate_pin,'extra_field':True}).encode()}))
 for payload in (b'[]',b'{}',b'not-json',b'{"version":1,"version":1}'):
  reject(bad,package({**files,pin_path:payload}))
 with tempfile.TemporaryDirectory() as api_tmp:
  api_overlay=Path(api_tmp)
  assert invoke(api_overlay,package({**files,api_path:json.dumps(api).encode()})).returncode==0
  assert json.loads((api_overlay/api_path).read_text())==api
 for field,value in [('publicHost','wrong.example.invalid'),('upstream','http://192.168.13.2:8000'),('enabled','yes')]:
  reject(bad,package({**files,api_path:json.dumps({**api,field:value}).encode()}))
 reject(bad,package({**files,api_path:json.dumps({**api,'allowedRequests':[{'method':'POST','path':'/management'}]}).encode()}))
 for payload in (b'[]',b'{}',b'not-json',b'{"duplicate":1,"duplicate":2}'):
  reject(bad,package({**files,manifest_path:payload}))
  reject(bad,package({**files,managed_path:payload}))
 for field,value in (('version',True),('version',2),('hostname','wrong.example.invalid'),
   ('origin_sni','wrong.example.invalid'),('lucky_rule_key','bad key'),('ddns_task_key','bad key'),('ssl_task_key',''),
   ('origin_header_secret','short'),('username','wrong-user'),('password','short'),('password','line\nbreak')):
  reject(bad,package({**files,manifest_path:json.dumps({**manifest,field:value}).encode()}))
 for field in manifest:
  reject(bad,package({**files,manifest_path:json.dumps({k:v for k,v in manifest.items() if k!=field}).encode()}))
 for field in managed:
  reject(bad,package({**files,managed_path:json.dumps({k:v for k,v in managed.items() if k!=field}).encode()}))
 # Distinct parseable bundles exercise the shared production semantic contract.
 # Each mutation changes one approved service, credential or identifier boundary.
 changes=[
  (('version',),2),(('domain_suffix',),'unapproved.invalid'),
  (('rule','RuleKey'),'differentRule'),(('ddns','TaskKey'),'differentDdns'),(('ssl','Key'),'differentSsl'),
  (('rule','RuleName'),'unmanaged'),(('ddns','TaskName'),'unmanaged'),(('ssl','Remark'),'unmanaged'),
  (('rule','ListenIP'),'0.0.0.0'),(('rule','ListenPort'),22),(('rule','EnableTLS'),True),(('rule','Http3'),True),
  (('rule','DefaultProxy','WebServiceType'),'reverseproxy'),
  (('rule','ProxyList',0,'Domains'),['other.example.invalid']),
  (('rule','ProxyList',0,'Locations'),['http://192.168.13.9:22']),
  (('rule','ProxyList',0,'EnableBasicAuth'),False),(('rule','ProxyList',0,'WebAuth'),False),
  (('rule','ProxyList',0,'BasicAuthUserList'),'cpe-temp:DifferentFixturePasswordValue123'),
  (('rule','ProxyList',0,'OtherParams','BasicAuthRegConf'),'/public'),
  (('rule','ProxyList',0,'OtherParams','AutoOptionsFirewall'),True),
  (('ddns','V4QueryIPEnable'),True),(('ddns','TaskType'),'IPv4'),
  (('ddns','V6GetIPScript'),'/unapproved-command'),(('ddns','DNS','Name'),'other-provider'),
  (('ddns','DNS','CallAPINetwork'),'tcp6'),(('ddns','DNS','ID'),'short'),
  (('ddns','DNS','Secret'),'DifferentDedicatedDNSSecret'),
  (('ddns','Records',0,'SyncRecordData','type'),'A'),
  (('ddns','Records',0,'SyncRecordData','fullDomainName'),'other.example.invalid'),
  (('ssl','ExtParams','acmeDomains'),['other.example.invalid']),
  (('ssl','ExtParams','acmeDNSSecret'),'DifferentDedicatedDNSSecret'),
  (('ssl','MappingPath'),'/unapproved-path'),(('ssl','MappingChangeScript'),'/unapproved-command'),
  (('ssl','AllSyncClient'),True)]
 for path,value in changes:
  altered=copy.deepcopy(managed);cursor=altered
  for part in path[:-1]:cursor=cursor[part]
  cursor[path[-1]]=value
  reject(bad,package({**files,managed_path:json.dumps(altered).encode()}))
 # Node is mandatory when a private bundle exists; missing validators cannot
 # downgrade this to the older object-only JSON check.
 no_node=base/'no-node';no_node.mkdir()
 for binary in ('python3','dirname'):
  resolved=shutil.which(binary);assert resolved
  (no_node/binary).symlink_to(resolved)
 reject(bad,encoded,changed={'PATH':str(no_node)})
 # Inspect only transport booleans. The wrapper deliberately emits fixture
 # credentials, proving both validator output streams stay suppressed.
 node_audit=base/'node-audit.json';node_bin=base/'node-bin';node_bin.mkdir()
 wrapper=node_bin/'node'
 wrapper.write_text('#!'+sys.executable+'\n'+'''import json, os, subprocess, sys
from pathlib import Path
data=sys.stdin.buffer.read();values=json.loads(data)
private=[values['manifest']['password'],values['managed']['ddns']['DNS']['ID'],values['managed']['ddns']['DNS']['Secret']]
audit={'stdin_seen':bool(data),'secret_in_argv':any(value in arg for value in private for arg in sys.argv),
       'bundle_env_found':any('CPE_LUCKY_REMOTE_BUNDLE_'+str(index) in os.environ for index in range(1,7))}
Path('''+repr(str(node_audit))+''').write_text(json.dumps(audit))
print(private[0]);print(private[-1],file=sys.stderr)
result=subprocess.run(['''+repr(node_binary)+''',*sys.argv[1:]],input=data,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
sys.exit(result.returncode)
''')
 wrapper.chmod(0o755)
 assert invoke(target,encoded,changed={'PATH':str(node_bin)+os.pathsep+environment.get('PATH','/usr/bin:/bin')}).returncode==0
 assert json.loads(node_audit.read_text())=={'stdin_seen':True,'secret_in_argv':False,'bundle_env_found':False}
 # Fault the second staged rename after replacing an existing first file.
 # This exercises actual directory-FD rollback and retains the original inode.
 embedded=script.read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
 definitions=ast.parse(embedded);assert isinstance(definitions.body[-1],ast.Try)
 definitions.body.pop();scope={'__name__':'fixture_injector'}
 exec(compile(definitions,str(script),'exec'),scope)
 transaction=base/'transaction';transaction.mkdir()
 first_name=sorted(files)[0];old=transaction/first_name;old.parent.mkdir(parents=True,mode=0o755)
 old.write_bytes(b'previous fixture generation');old.chmod(0o644);old.parent.chmod(0o755)
 original_inode=old.stat().st_ino;before=snapshot(transaction);original_replace=os.replace;renames=0
 def interrupted(source,destination,**kw):
  global renames
  if str(source).endswith('.new'):
   renames+=1
   if renames==2:raise OSError('fixture interrupted staged rename')
  return original_replace(source,destination,**kw)
 os.replace=interrupted
 try:
  try:scope['install'](transaction,files)
  except OSError:pass
  else:raise AssertionError('injected install fault ignored')
 finally:os.replace=original_replace
 assert renames==2 and snapshot(transaction)==before and old.stat().st_ino==original_inode
 # Existing nonregular or multiply linked destinations fail before any write.
 for kind in ('symlink','hardlink','fifo'):
  folder=base/('destination-'+kind);file=folder/managed_path;file.parent.mkdir(parents=True)
  outside_file=base/('outside-'+kind);outside_file.write_bytes(b'outside fixture sentinel')
  if kind=='symlink':file.symlink_to(outside_file)
  elif kind=='hardlink':os.link(outside_file,file)
  else:os.mkfifo(file)
  reject(folder,encoded);assert outside_file.read_bytes()==b'outside fixture sentinel'
 unsafe=base/'unsafe';unsafe.mkdir();outside=base/'outside';outside.mkdir();(outside/'sentinel').write_text('outside')
 (unsafe/'etc').symlink_to(outside,target_is_directory=True);reject(unsafe,encoded)
 assert (outside/'sentinel').read_text()=='outside'
 for i,name in enumerate(paths):
  if name=='etc/cpe5g/public-origin.json':continue
  sole=base/('sole-'+str(i));file=sole/name;file.parent.mkdir(parents=True);file.write_bytes(files[name])
  r=subprocess.run(['bash',str(guard),str(sole)],capture_output=True,timeout=10)
  assert r.returncode==0 and b'WRT_PRIVATE_BUILD=true\n' in r.stdout and b'cpe-lucky-private-seed' in r.stdout
  assert b'fixture-only-placeholder' not in r.stdout+r.stderr
 empty=base/'empty';(empty/'etc/cpe5g-lucky/tls').mkdir(parents=True);(empty/'etc/cpe5g-lucky/tls/health-client.key').touch()
 r=subprocess.run(['bash',str(guard),str(empty)],capture_output=True)
 assert r.returncode==0 and b'WRT_PRIVATE_BUILD=false\n' in r.stdout
print('CPE Lucky private seed: %d injection fixtures and sole-file privacy checks passed'%cases)
PY
