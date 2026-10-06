#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/overlay/usr/libexec"
printf '#!/bin/sh\nexit 0\n' >"$TMP_DIR/overlay/usr/libexec/cpe5g-mwan3-gated-reconcile"
chmod 755 "$TMP_DIR/overlay/usr/libexec/cpe5g-mwan3-gated-reconcile"
"$ROOT_DIR/Scripts/ConfigureCpeIpv6.sh" "$TMP_DIR/overlay" true >/dev/null
WRAPPER="$TMP_DIR/overlay/usr/libexec/cpe5g-lucky-origin-start"
test -x "$WRAPPER"
sh -n "$WRAPPER"

# Exercise the generated wrapper, not a copy of its conditions. Rewrite only
# its host paths; all gate/config/cgroup data and commands stay in fixtures.
python3 - "$TMP_DIR" "$WRAPPER" "$(command -v awk)" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys

root, original, awk = map(Path, sys.argv[1:])
source = original.read_text()
mock_source = r'''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['CPE_LUCKY_STARTUP_FIXTURE'])
settings=json.loads((root/'settings.json').read_text())
name=Path(sys.argv[0]).name
args=sys.argv[1:]
def event(kind,**data):
 with (root/'events.jsonl').open('a') as f:f.write(json.dumps({'event':kind,**data})+'\n')
if name=='uci':
 assert args[:2]==['-q','get'],args
 event('uci',key=args[2])
 value=settings['uci'].get(args[2])
 if value is None:sys.exit(1)
 print(value)
elif name=='jsonfilter':
 assert args==['-i',str(root/'root/wrtbak/firstboot/gate.json'),'-e','@.state'],args
 event('gate-read')
 try:print(json.loads(Path(args[1]).read_text())['state'])
 except (OSError,ValueError,KeyError):sys.exit(1)
elif name=='sleep':
 assert args==['5'],args
 count=settings.get('sleeps',0)+1
 event('sleep',count=count)
 if count>settings.get('max_sleeps',3):sys.exit(124)
 settings['sleeps']=count
 action=settings.get('on_sleep',{}).get(str(count),{})
 if 'mounts' in action:(root/'proc/mounts').write_text(action['mounts'])
 if 'gate' in action:(root/'root/wrtbak/firstboot/gate.json').write_text(json.dumps({'state':action['gate']}))
 for group in action.get('groups',[]):(root/'sys/fs/cgroup/services'/group).mkdir(parents=True,exist_ok=True)
 (root/'settings.json').write_text(json.dumps(settings))
elif name=='node':
 assert len(args)==1,args
 module=Path(args[0]).name
 assert Path(args[0]).parent==root/'usr/libexec/cpe5g-ipv6',args
 assert module in ['restore-lucky-private.mjs','reconcile-lucky-managed.mjs','lucky-origin.mjs'],args
 event('node',module=module)
 if module==settings.get('fail_node'):sys.exit(31)
elif name=='nikki':
 assert args in [['status'],['reload']],args
 event('nikki',action=args[0])
 if args==['status'] and not settings.get('nikki_running',True):sys.exit(1)
elif name=='cpe5g-lucky-persist':
 event('persist')
 if settings.get('fail_persist'):sys.exit(32)
elif name=='wrtbak':
 event('unexpected-wrtbak-execution')
 sys.exit(91)
else:raise AssertionError(name)
'''
EXT4 = '/dev/fixture /data ext4 rw 0 0\n'
MODULES = ['restore-lucky-private.mjs', 'reconcile-lucky-managed.mjs', 'lucky-origin.mjs']
cases = 0

def run_case(name, *, mounts=EXT4, enabled=None, implementation=False,
             script=True, binary=True, gate=None, invalid_gate=False,
             nikki=False, controllers=False, groups=(), nikki_script=True,
             nikki_running=True, on_sleep=None, max_sleeps=3, fail_node=None,
             expected_sleeps=0, expected_status=0, expected_reload=False,
             expected_gate_reads=None, expected_nodes=None):
    global cases
    case_root = root/name
    for rel in ['bin', 'data', 'proc', 'root/wrtbak/firstboot', 'etc/init.d',
                'sys/fs/cgroup/services', 'usr/libexec/cpe5g-ipv6']:
        (case_root/rel).mkdir(parents=True)
    (case_root/'proc/mounts').write_text(mounts)
    if gate is not None:
        (case_root/'root/wrtbak/firstboot/gate.json').write_text(json.dumps({'state':gate}))
    if invalid_gate:
        (case_root/'root/wrtbak/firstboot/gate.json').write_text('{broken fixture')
    if controllers:
        (case_root/'sys/fs/cgroup/cgroup.controllers').touch()
    for group in groups:
        (case_root/'sys/fs/cgroup/services'/group).mkdir()
    config = {}
    if enabled is not None:
        config['wrtbak.main.firstboot_auto_enabled'] = enabled
    if nikki:
        config['nikki.config'] = 'config'
    settings = {'uci':config, 'on_sleep':on_sleep or {}, 'max_sleeps':max_sleeps,
                'fail_node':fail_node, 'nikki_running':nikki_running}
    (case_root/'settings.json').write_text(json.dumps(settings))
    mock = case_root/'mock.py'
    mock.write_text(mock_source)
    mock.chmod(0o755)
    for command in ['uci', 'jsonfilter', 'sleep', 'node', 'cpe5g-lucky-persist']:
        (case_root/'bin'/command).symlink_to(mock)
    (case_root/'bin/awk').symlink_to(awk)
    if implementation and binary:
        (case_root/'bin/wrtbak').symlink_to(mock)
    if implementation and script:
        marker = case_root/'etc/init.d/wrtbak-firstboot-auto'
        marker.write_text('#!/bin/sh\nexit 0\n')
        marker.chmod(0o755)
    if nikki_script:
        (case_root/'etc/init.d/nikki').symlink_to(mock)
    rewritten = source
    for path in ['/proc/mounts', '/root/wrtbak/firstboot/gate.json',
                 '/etc/init.d/wrtbak-firstboot-auto', '/etc/init.d/nikki',
                 '/sys/fs/cgroup', '/usr/libexec/cpe5g-ipv6']:
        rewritten = rewritten.replace(path, str(case_root/path.lstrip('/')))
    rewritten = rewritten.replace('/usr/bin/node',str(case_root/'bin/node'))
    rewritten = rewritten.replace('/usr/libexec/cpe5g-lucky-persist',str(case_root/'bin/cpe5g-lucky-persist'))
    wrapper = case_root/'wrapper.sh'
    wrapper.write_text(rewritten)
    env = dict(os.environ, PATH=str(case_root/'bin'),
               CPE_LUCKY_STARTUP_FIXTURE=str(case_root))
    result = subprocess.run(['/bin/sh',str(wrapper)],env=env,text=True,
                            capture_output=True,timeout=5)
    events = [json.loads(line) for line in (case_root/'events.jsonl').read_text().splitlines()]
    assert result.returncode == expected_status, (name,result.returncode,result.stderr,events)
    sleeps = [e for e in events if e['event']=='sleep']
    assert len(sleeps)==expected_sleeps,(name,sleeps)
    nodes = [e['module'] for e in events if e['event']=='node']
    if nodes:
        assert [e['event'] for e in events].index('persist') < [e['event'] for e in events].index('node'), events
    if expected_nodes is not None:
        assert nodes==expected_nodes,(name,nodes)
        assert not any(e['event']=='nikki' for e in events),(name,events)
    elif fail_node:
        assert nodes==MODULES[:MODULES.index(fail_node)+1],(name,nodes)
        assert not any(e['event']=='nikki' for e in events),(name,events)
    elif expected_status:
        assert nodes==[],(name,nodes)
    else:
        assert nodes==MODULES,(name,nodes)
    reloads = [e for e in events if e['event']=='nikki' and e['action']=='reload']
    assert len(reloads)==int(expected_reload),(name,reloads)
    if expected_reload:
        order = [(e['event'],e.get('module',e.get('action'))) for e in events
                 if e['event'] in ['node','nikki']]
        assert order==[('node',MODULES[0]),('node',MODULES[1]),
                       ('nikki','status'),('nikki','reload'),('node',MODULES[2])],(name,order)
    if expected_gate_reads is not None:
        assert sum(e['event']=='gate-read' for e in events)==expected_gate_reads,(name,events)
    assert not any(e['event']=='unexpected-wrtbak-execution' for e in events),(name,events)
    cases += 1
    return events

# Neither directory existence nor a non-ext4 mount satisfies the data gate.
events = run_case('data-becomes-ext4',mounts='',on_sleep={
    '1':{'mounts':'tmpfs /data tmpfs rw 0 0\n'},'2':{'mounts':EXT4}},expected_sleeps=2)
assert max(i for i,e in enumerate(events) if e['event']=='sleep') < next(i for i,e in enumerate(events) if e['event']=='node')
for label,mounts in [('missing',''),('wrong-filesystem','/dev/fixture /data f2fs rw 0 0\n'),
                     ('wrong-mountpoint','/dev/fixture / ext4 rw 0 0\n')]:
    run_case('data-blocks-'+label,mounts=mounts,max_sleeps=2,
             expected_sleeps=3,expected_status=124)

# An enabled, operative wrtbak must reach a terminal restore decision.
run_case('restore-becomes-terminal',enabled='1',implementation=True,gate='pending',
         on_sleep={'1':{'gate':'restoring'},'2':{'gate':'restored'}},
         expected_sleeps=2,expected_gate_reads=3)
run_case('both-data-and-restore-required',mounts='',enabled='1',implementation=True,
         gate='pending',on_sleep={'1':{'gate':'restored'},'2':{'mounts':EXT4}},
         expected_sleeps=2,expected_gate_reads=3)
for terminal in ['already_done','restored','no_backup','failed_final','disabled']:
    run_case('restore-terminal-'+terminal,enabled='1',implementation=True,
             gate=terminal,expected_gate_reads=1)
for label,kwargs in [('missing',{}),('malformed',{'invalid_gate':True}),
                     ('unknown',{'gate':'unrecognized-state'})]:
    run_case('restore-blocks-'+label,enabled='1',implementation=True,
             max_sleeps=1,expected_sleeps=2,expected_status=124,
             expected_gate_reads=2,**kwargs)
for enabled in ['true','yes','on','enabled']:
    run_case('restore-enabled-'+enabled,enabled=enabled,implementation=True,
             gate='no_backup',expected_gate_reads=1)
run_case('restore-disabled',enabled='0',implementation=True,gate='pending',expected_gate_reads=0)
for label,script,binary in [('missing-script',False,True),('missing-binary',True,False),
                            ('missing-both',False,False)]:
    run_case('orphan-'+label,enabled='1',implementation=True,script=script,
             binary=binary,gate='pending',expected_gate_reads=0)

# Restore and managed repair finish before conditional cgroup waits/reload.
events = run_case('nikki-groups-become-ready',nikki=True,controllers=True,
                 on_sleep={'1':{'groups':['lucky']},'2':{'groups':['cpe5g-lucky-origin']}},
                 expected_sleeps=2,expected_reload=True)
first_sleep = next(i for i,e in enumerate(events) if e['event']=='sleep')
assert [e['module'] for e in events[:first_sleep] if e['event']=='node']==MODULES[:2]
assert max(i for i,e in enumerate(events) if e['event']=='sleep') < next(i for i,e in enumerate(events) if e['event']=='nikki')
run_case('nikki-origin-group-never-ready',nikki=True,controllers=True,
         groups=['lucky'],max_sleeps=1,expected_sleeps=2,
         expected_status=124,expected_nodes=MODULES[:2])
run_case('nikki-no-config',controllers=True)
run_case('nikki-no-cgroup2',nikki=True)
run_case('nikki-stopped',nikki=True,controllers=True,
         groups=['lucky','cpe5g-lucky-origin'],nikki_running=False)
run_case('nikki-init-missing',nikki=True,controllers=True,
         groups=['lucky','cpe5g-lucky-origin'],nikki_script=False)
for module in MODULES[:2]:
    run_case('module-fails-'+module,nikki=True,controllers=True,
             fail_node=module,expected_status=31)
print(f'CPE Lucky startup wrapper passed ({cases} fixture scenarios; no real waits)')
PYTEST
