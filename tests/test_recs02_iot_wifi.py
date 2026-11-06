#!/usr/bin/env python3
"""Execute the firstboot hook against real UCI (or a command-boundary fixture)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / 'files/etc/uci-defaults/99-iot-2g-wifi'

# Only the external UCI command is substituted on CI hosts without libuci.
UCI_FIXTURE = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['UCI_STATE']); d=json.loads(p.read_text())
a=[x for x in sys.argv[1:] if x != '-q']; op=a[0]; arg=a[1]
if op == 'show':
    for k,v in d.items(): print(k+'='+v if '.' not in k[9:] else k+"='"+v+"'")
elif op == 'get':
    if arg not in d: sys.exit(1)
    print(d[arg])
elif op == 'set':
    k,v=arg.split('=',1); d[k]=v; p.write_text(json.dumps(d))
elif op == 'delete':
    if arg not in d: sys.exit(1)
    del d[arg]; p.write_text(json.dumps(d))
elif op != 'commit': sys.exit(2)
'''

class WifiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.d = Path(self.temp.name)
        self.board = self.d/'board'; self.board.write_text('jdcloud,re-cs-02\n')
        self.key = self.d/'key'; self.key.write_text('fixture-psk-$quote\'"')
        self.state = self.d/'state'
        self.b = self.d/'bin'; self.b.mkdir()
        self.config = self.d/'config'; self.config.mkdir()
        self.delta = self.d/'delta'; self.delta.mkdir()
        real = os.environ.get('RECS02_TEST_UCI')
        self.real = real
        uci = self.b/'uci'
        if real:
            import shlex
            uci.write_text('#!/bin/sh\nexec '+shlex.quote(real)+' -c "$UCI_CONFIG" -t "$UCI_DELTA" -P "$UCI_DELTA" "$@"\n')
        else:
            uci.write_text(UCI_FIXTURE)
        uci.chmod(0o755)
        (self.b/'wifi').write_text('#!/bin/sh\nexit 0\n'); (self.b/'wifi').chmod(0o755)
        self.env = {**os.environ,'PATH':str(self.b)+':'+os.environ['PATH'],
                    'UCI_STATE':str(self.state),'UCI_CONFIG':str(self.config), 'UCI_DELTA':str(self.delta),
                    'RECS02_BOARD_FILE':str(self.board),'RECS02_IOT_KEY_FILE':str(self.key)}
    def uci(self, *args):
        return subprocess.check_output([str(self.b/'uci'),*args],env=self.env,text=True).strip()
    def seed(self, radios=('radio7','radio9')):
        values={}
        for i,radio in enumerate(('high',*radios,'low')):
            values['wireless.'+radio]='wifi-device'
            values['wireless.'+radio+'.band']='2g' if radio in radios else '5g'
            for k,v in {'require_mode':'ax','htmode':'HT20' if radio in radios else 'HE80','channel':'149' if radio=='high' else '36','country':'CN','disabled':'1'}.items():
                values['wireless.'+radio+'.'+k]=v
            ap='ap'+str(i)
            values['wireless.'+ap]='wifi-iface'
            for k,v in {'device':radio,'mode':'ap','network':'lan','ssid':'before','encryption':'sae','key':'fixture-before','disabled':'1','ieee80211r':'1','ieee80211k':'1','bss_transition':'1'}.items():
                values['wireless.'+ap+'.'+k]=v
        values.update({'wireless.uplink':'wifi-iface','wireless.uplink.device':radios[0], 'wireless.uplink.mode':'sta','wireless.uplink.key':'keep-uplink'})
        self.values=values
        if self.real:
            (self.config/'wireless').touch()
            for k,v in values.items(): self.uci('set',k+'='+v)
            self.uci('commit','wireless')
        else: self.state.write_text(json.dumps(values))
    def run_hook(self):
        return subprocess.run(['sh',str(HOOK)],env=self.env,capture_output=True,text=True)
    def test_dynamic_bands_security_and_repeat(self):
        self.seed()
        before=self.uci('show','wireless')
        for _ in range(2):
            result=self.run_hook(); self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn(self.key.read_text(),result.stdout+result.stderr)
            for radio in ('radio7','radio9'):
                for k,v in {'ieee80211n':'0','ieee80211ax':'0','ieee80211d':'0','legacy_rates':'1','channel':'6','country':'CN','disabled':'0'}.items():
                    self.assertEqual(self.uci('get','wireless.'+radio+'.'+k),v)
                for option in ('htmode','require_mode'):
                    p=subprocess.run([str(self.b/'uci'),'-q','get','wireless.'+radio+'.'+option],env=self.env,capture_output=True)
                    self.assertNotEqual(p.returncode,0)
            for ap in ('ap1','ap2'):
                for k,v in {'ssid':'DAE-WRT-IoT','encryption':'psk2+ccmp','key':self.key.read_text(),'ieee80211w':'0','uapsd':'0','disassoc_low_ack':'0','ieee80211r':'0','ieee80211k':'0','bss_transition':'0','disabled':'0'}.items():
                    self.assertEqual(self.uci('get','wireless.'+ap+'.'+k),v)
            after=self.uci('show','wireless')
            for section in ('high','low','ap0','ap3','uplink'):
                prefix='wireless.'+section
                self.assertEqual([x for x in before.splitlines() if x.startswith(prefix+'=') or x.startswith(prefix+'.')],
                                 [x for x in after.splitlines() if x.startswith(prefix+'=') or x.startswith(prefix+'.')])
    def test_wrong_board_missing_key_and_radio_retry(self):
        self.seed(); before=self.uci('show','wireless')
        self.board.write_text('jdcloud,re-ss-01')
        self.assertEqual(self.run_hook().returncode,0)
        self.assertEqual(before,self.uci('show','wireless'))
        self.board.write_text('jdcloud,re-cs-02'); self.key.unlink()
        self.assertEqual(self.run_hook().returncode,0)
        self.assertEqual(before,self.uci('show','wireless'))
        self.key.write_text('fixture-psk')
        for radio in ('radio7','radio9'): self.uci('set','wireless.'+radio+'.band=5g')
        self.assertNotEqual(self.run_hook().returncode,0)
    def test_private_injection_and_guard(self):
        overlay=self.d/'overlay'
        generator=ROOT/'Scripts/ConfigureReCs02IotWifi.sh'
        env={**os.environ,'WRT_CONFIG':'IPQ60XX-RE-CS-02','WRT_ENCRYPT_ARTIFACT':'true','RE_CS02_IOT_WIFI_PASSWORD':self.key.read_text()}
        def generate(**changes):
            return subprocess.run(['bash',str(generator),str(overlay)],env={**env,**changes},capture_output=True,text=True)
        self.assertNotEqual(generate(RE_CS02_IOT_WIFI_PASSWORD='').returncode,0)
        self.assertNotEqual(generate(WRT_ENCRYPT_ARTIFACT='false').returncode,0)
        self.assertEqual(generate(WRT_CONFIG='IPQ60XX-RE-SS-01').returncode,0)
        self.assertFalse(overlay.exists())
        result=generate(); self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn(self.key.read_text(),result.stdout+result.stderr)
        key=overlay/'etc/re-cs-02/iot-wifi.key'
        self.assertEqual(key.read_text(),self.key.read_text()); self.assertEqual(key.stat().st_mode&0o777,0o600)
        self.assertEqual(key.parent.stat().st_mode&0o777,0o700)
        guard=subprocess.check_output(['bash',str(ROOT/'Scripts/PrivateFirmwareGuard.sh'),str(overlay)],text=True,stderr=subprocess.DEVNULL)
        self.assertIn('WRT_PRIVATE_BUILD=true',guard); self.assertIn('recs02-iot-wifi-credential',guard)

if __name__=='__main__': unittest.main()
