#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$REPO" <<'PY'
from pathlib import Path
import os, re, subprocess, tempfile
repo=Path(__import__('sys').argv[1])
source=(repo/'Scripts/cpe5g-lucky-persist').read_text()
mock=r'''#!/usr/bin/python3
import os,sys
from pathlib import Path
r=Path(os.environ['LUCKY_FIXTURE']);name=Path(sys.argv[0]).name;a=sys.argv[1:]
if name=='logger':sys.exit(0)
if name=='uci':sys.exit(1)
if name=='ubus':print('{}');sys.exit(0)
if name=='jsonfilter':
 print('/usr/libexec/cpe5g-lucky-start' if (r/'already-guarded').exists() else '/unrecognized/lucky' if (r/'foreign-launcher').exists() else '/usr/bin/lucky');sys.exit(0)
if name=='pgrep':sys.exit(0 if (r/'writer').exists() else 1)
if name=='mount':
 assert a==['-o','bind',str(r/'data/lucky'),str(r/'etc/lucky')],a
 (r/'bound').touch();(r/'proc/self/mountinfo').write_text('1 0 0:1 / '+str(r/'etc/lucky')+' rw - ext4 /dev/fixture rw\n');sys.exit(0)
if name=='sleep':
 if (r/'recover-mount').exists():
  (r/'proc/mounts').write_text('/dev/fixture '+str(r/'data')+' ext4 rw 0 0\n');sys.exit(0)
 sys.exit(42)
if name=='stat':
 if a[1]=='%u':print(0);sys.exit(0)
 if a[1]=='%u:%a':print('0:600');sys.exit(0)
 if a[1]=='%d:%i' and (r/'bound').exists() and a[2] in [str(r/'data/lucky'),str(r/'etc/lucky')]:print('1:100');sys.exit(0)
 os.execv('/usr/bin/stat',['stat',*a])
raise AssertionError((name,a))
'''
count=0
with tempfile.TemporaryDirectory() as temp:
 base=Path(temp)
 def case(name, setup=None, ok=True):
  global count
  r=base/name
  for p in ['data','etc/lucky','proc/self','bin','root/wrtbak','etc/init.d','var/run']:(r/p).mkdir(parents=True,exist_ok=True)
  (r/'etc/lucky/lucky_base.lkcf').write_text('original settings')
  (r/'etc/lucky/cert-sync').mkdir();(r/'etc/lucky/cert-sync/current').symlink_to('release-owned')
  (r/'proc/mounts').write_text('/dev/fixture '+str(r/'data')+' ext4 rw 0 0\n')
  (r/'proc/self/mountinfo').write_text('')
  m=r/'mock';m.write_text(mock);m.chmod(0o755)
  for n in ['logger','uci','ubus','jsonfilter','pgrep','mount','sleep','stat']:(r/'bin'/n).symlink_to(m)
  if setup:setup(r)
  paths=['/rom/etc/init.d/lucky','/etc/init.d/lucky','/etc/init.d/.lucky-cpe5g-new','/proc/self/mountinfo','/proc/mounts','/etc/init.d/wrtbak-firstboot-auto','/root/wrtbak/firstboot/gate.json','/var/run/cpe5g-lucky-persist','/etc/lucky','/data']
  text=re.sub('|'.join(re.escape(p) for p in sorted(paths,key=len,reverse=True)),lambda m:str(r/m[0].lstrip('/')),source)
  script=r/'persist';script.write_text(text)
  env=dict(os.environ,PATH=str(r/'bin')+':'+os.environ['PATH'],LUCKY_FIXTURE=str(r))
  result=subprocess.run(['/bin/sh',str(script)],env=env,capture_output=True,text=True,timeout=4)
  assert (result.returncode==0)==ok,(name,result.returncode,result.stderr)
  if not ok:assert not (r/'bound').exists(),name
  count+=1
  return r,script,env
 def persistent(r):
  d=r/'data/lucky';d.mkdir(mode=0o700)
  (d/'lucky_base.lkcf').write_text('administrator changes')
  (d/'.cpe5g-persist-v1').write_text('1\n');(d/'.cpe5g-persist-v1').chmod(0o600)
 r,script,env=case('first-migration')
 assert (r/'data/lucky/lucky_base.lkcf').read_text()=='original settings'
 assert (r/'data/lucky/cert-sync/current').is_symlink()
 (r/'writer').touch()
 assert subprocess.run(['/bin/sh',str(script)],env=env).returncode==0,'same mount is idempotent with active Lucky'
 r,_,_=case('retained-upgrade',persistent)
 assert (r/'data/lucky/lucky_base.lkcf').read_text()=='administrator changes'
 case('source-symlink',lambda r:(r/'data/lucky').symlink_to(r/'etc/lucky'),ok=False)
 case('active-writer',lambda r:(r/'writer').touch(),ok=False)
 case('foreign-data',lambda r:(r/'data/lucky').mkdir(),ok=False)
 case('foreign-mount',lambda r:(r/'proc/self/mountinfo').write_text('1 0 0:1 / '+str(r/'etc/lucky')+' rw - ext4 /dev/foreign rw\n'),ok=False)
 case('missing-emmc',lambda r:(r/'proc/mounts').write_text('tmpfs '+str(r/'data')+' tmpfs rw 0 0\n'),ok=False)
 def late(r):
  (r/'proc/mounts').write_text('');(r/'recover-mount').touch()
 case('late-emmc',late)
 def marker_link(r):
  persistent(r);(r/'data/lucky/.cpe5g-persist-v1').unlink();(r/'data/lucky/.cpe5g-persist-v1').symlink_to(r/'etc/lucky/lucky_base.lkcf')
 case('marker-symlink',marker_link,ok=False)
 case('restored-marker-symlink',lambda r:(r/'etc/lucky/.cpe5g-persist-v1').symlink_to(r/'etc/lucky/lucky_base.lkcf'),ok=False)
 def old_launcher(r):
  (r/'rom/etc/init.d').mkdir(parents=True)
  old=r/'etc/init.d/lucky';old.write_text('#!/bin/sh\nprintf "old-%s\\n" "$1" >> "'+str(r/'launcher-events')+'"\n');old.chmod(0o755)
  new=r/'rom/etc/init.d/lucky';new.write_text('#!/bin/sh\n# /usr/libexec/cpe5g-lucky-start\nprintf "new-%s\\n" "$1" >> "'+str(r/'launcher-events')+'"\n')
 r,_,_=case('retained-old-launcher',old_launcher)
 assert (r/'launcher-events').read_text().splitlines()==['old-stop','new-start']
 assert (r/'etc/init.d/lucky').read_bytes()==(r/'rom/etc/init.d/lucky').read_bytes()
 def guarded(r):old_launcher(r);(r/'already-guarded').touch()
 r,_,_=case('guarded-worker-does-not-stop-itself',guarded)
 assert not (r/'launcher-events').exists()
 def foreign(r):old_launcher(r);(r/'foreign-launcher').touch()
 case('foreign-launcher-is-not-replaced',foreign,ok=False)
 print(f'CPE Lucky persistence: {count} behavioral cases passed')

 # Exercise startup's actual CLI argument construction. A failed mount must
 # prevent both settings writes and opening the management/proxy listeners.
 for safe,fail in [('',False),('/private-management-path',False),('',True)]:
  r=base/('startup-'+str(count));r.mkdir();count+=1
  mock=r/'command';mock.write_text('''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
r=Path(os.environ['START_FIXTURE']);a=sys.argv[1:]
name=Path(sys.argv[0]).name
if name=='uci':
 print(os.environ['SAFE'] if a[-1].endswith('.safe') else '16601');sys.exit(0)
if name=='persist':sys.exit(int(os.environ['FAIL']))
with (r/'calls').open('a') as f:f.write(json.dumps(a)+'\\n')
if a[0]=='-setconf':assert a[1]=='-key' and a[-2:]==['-cd',str(r/'etc/lucky')]
else:assert a==['-cd',str(r/'etc/lucky')]
''');mock.chmod(0o755)
  for n in ['uci','persist','lucky']:(r/n).symlink_to(mock)
  text=(repo/'Scripts/cpe5g-lucky-start').read_text().replace('/usr/libexec/cpe5g-lucky-persist',str(r/'persist')).replace('/usr/bin/lucky',str(r/'lucky')).replace('/etc/lucky',str(r/'etc/lucky'))
  script=r/'start';script.write_text(text)
  env=dict(os.environ,PATH=str(r)+':'+os.environ['PATH'],SAFE=safe,FAIL=str(int(fail)),START_FIXTURE=str(r))
  result=subprocess.run(['/bin/sh',str(script)],env=env,capture_output=True,text=True)
  assert (result.returncode!=0)==fail,result.stderr
  if fail:assert not (r/'calls').exists()
  else:
   import json
   calls=[json.loads(x) for x in (r/'calls').read_text().splitlines()]
   assert len(calls)==3 and calls[1][2:5]==['SafeURL','-value',safe],calls
 print('CPE Lucky startup: empty/nonempty SafeURL and mount failure passed')
PY
