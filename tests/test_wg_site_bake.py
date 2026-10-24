#!/usr/bin/env python3
"""Private seed validation, real bootstrap command contract and path failover."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.files = self.dir / 'files'
        self.env = {**os.environ, 'WG_PRIV_KEY': base64.b64encode(bytes(range(1,33))).decode(),
                    'WG_PEER_PUB': base64.b64encode(bytes(range(33,65))).decode(),
                    'DDNSGO_DOMAIN':'ss0112.jmsu.top','DDNSGO_AK':'fixture-ak',
                    'DDNSGO_SK': 'fixture-secret-"\\\\$', 'U2R_ENABLE':'0'}
    def seed(self, role='server', **overrides):
        return subprocess.run(['bash',str(ROOT/'Scripts/ConfigureWgSiteToSite.sh'),str(self.files),role],
                              env={**self.env,**overrides},text=True,capture_output=True)
    def setup_bin(self):
        b=self.dir/'bin'; b.mkdir(); log=self.dir/'calls'; log.write_text('')
        script='''#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$CALLS"
case "$(basename "$0"):$*" in
  "wg:pubkey") cat >/dev/null; printf '%s\\n' "$LOCAL_PUB";;
  "wg:show wg0 latest-handshakes") printf '%s 1\\n' "$PEER";;
  "ping:"*) exit "${PING_RC:-0}";;
  "uci:-q batch") cat >> "$CALLS";;
  "crontab:-l") exit 0;;
  "crontab:-") cat >> "$CALLS";;
esac
exit 0
'''
        for cmd in ['wg','ip','ping','uci','ifup','logger','ubus','crontab','nslookup']:
            f=b/cmd; f.write_text(script); f.chmod(0o700)
        init=self.dir/'init';init.mkdir()
        for cmd in ['firewall','ddns-go','wg-path-daemon']:
            f=init/cmd;f.write_text(script);f.chmod(0o700)
        config=self.files/'etc/wg-site/site.conf'
        vals=subprocess.check_output(['sh','-c','. "$1"; printf "%s\\n%s" "$WG_LOCAL_PUB" "$WG_PEER_PUB"','sh',str(config)],text=True).splitlines()
        env={**os.environ,'PATH':str(b)+':'+os.environ['PATH'],'CALLS':str(log),
             'LOCAL_PUB':vals[0],'PEER':vals[1], 'WG_SITE_CONFIG':str(config),
             'WG_SITE_STATE':str(self.dir/'state'),'WG_SITE_DATA':str(self.dir/'data'),
             'WG_SITE_INIT_DIR':str(init),'WG_SITE_TEST':'1'}
        return env,log
    def test_private_seed_and_safe_quoting(self):
        r=self.seed();self.assertEqual(r.returncode,0,r.stderr)
        config=self.files/'etc/wg-site/site.conf';self.assertEqual(config.stat().st_mode&0o777,0o600)
        d=json.loads((self.files/'etc/ddns-go/ddns-go-config.yaml').read_text())
        self.assertEqual(d['dnsconf'][0]['dns']['secret'],self.env['DDNSGO_SK'])
        self.assertEqual(d['dnsconf'][0]['ipv4']['gettype'],'netInterface')
        self.assertEqual(d['dnsconf'][0]['ipv4']['netinterface'],'pppoe-wan')
        self.assertNotIn(self.env['DDNSGO_SK'],r.stdout+r.stderr)
        r=subprocess.run(['bash',str(ROOT/'Scripts/PrivateFirmwareGuard.sh'),str(self.files)],text=True,capture_output=True)
        self.assertIn('WRT_PRIVATE_BUILD=true',r.stdout);self.assertIn('wg-site-private-seed',r.stdout)
    def test_missing_and_self_peer_rejected(self):
        self.assertNotEqual(self.seed(WG_PRIV_KEY='').returncode,0)
        self.assertEqual(self.seed().returncode,0)
        c=self.files/'etc/wg-site/site.conf'
        pub=subprocess.check_output(['sh','-c','. "$1"; printf %s "$WG_LOCAL_PUB"','sh',str(c)],text=True)
        self.assertNotEqual(self.seed(WG_PEER_PUB=pub).returncode,0)
        self.assertNotEqual(self.seed(DDNSGO_SK='').returncode,0)
    def test_role_validation(self):
        self.assertNotEqual(self.seed('client').returncode,0)
        self.assertEqual(self.seed('client',DDNS_HOST='ss0112.jmsu.top').returncode,0)
        self.assertNotEqual(self.seed(DDNS_HOST='ss0112.jmsu.top').returncode,0)
        self.assertNotEqual(self.seed(U2R_ENABLE='1').returncode,0)
    def test_bootstrap_roles_and_identity_preservation(self):
        for role in ['server','client']:
            with self.subTest(role=role):
                self.assertEqual(self.seed(role,DDNS_HOST='ss0112.jmsu.top' if role=='client' else '').returncode,0)
                # Separate stubs per invocation of the bootstrap.
                if (self.dir/'bin').exists():
                    import shutil
                    shutil.rmtree(self.dir/'bin');shutil.rmtree(self.dir/'init')
                env,log=self.setup_bin()
                r=subprocess.run(['sh',str(ROOT/'files/usr/sbin/wg-site-init')],env=env,text=True,capture_output=True)
                self.assertEqual(r.returncode,0,r.stderr)
                calls=log.read_text()
                self.assertIn('network.wg0_peer_remote=wireguard_wg0',calls)
                self.assertIn("network.wg0.private_key='"+self.env['WG_PRIV_KEY']+"'",calls)
                self.assertIn("route_allowed_ips='0'",calls)
                self.assertIn("ipproto='udp'",calls)
                self.assertNotIn('route flush',calls)
                self.assertNotIn('route add',calls)
                self.assertEqual("firewall.wg_in=rule" in calls,role=='server')
                if role=='server':self.assertNotIn('endpoint_host=',calls)
                self.assertIn('ubus call network reload',calls)
                # An existing different key is never silently replaced.
                original=env['LOCAL_PUB'];env['LOCAL_PUB']='different'
                r=subprocess.run(['sh',str(ROOT/'files/usr/sbin/wg-site-init')],env=env,text=True,capture_output=True)
                self.assertNotEqual(r.returncode,0)
                env['LOCAL_PUB']=original
    def test_failover_recovery_and_old_handshake_with_live_ping(self):
        self.assertEqual(self.seed().returncode,0)
        env,log=self.setup_bin();daemon=ROOT/'files/usr/sbin/wg-path-daemon'
        def once(failed):
            r=subprocess.run(['sh',str(daemon),'once'],env={**env,'PING_RC':str(int(failed))},text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
        once(False)
        self.assertEqual((self.dir/'state/state').read_text().strip(),'udp')
        once(True);self.assertEqual((self.dir/'state/state').read_text().strip(),'udp')
        once(True);self.assertEqual((self.dir/'state/state').read_text().strip(),'ts')
        once(False);self.assertEqual((self.dir/'state/state').read_text().strip(),'udp')
        calls=log.read_text()
        self.assertIn('ping -I wg0',calls)
        self.assertIn('route del 192.168.11.0/24 dev wg0 table 60',calls)
        self.assertNotIn('table 52',calls)
        self.assertNotIn('route flush',calls)
        self.assertNotIn('ifdown',calls)

if __name__=='__main__':unittest.main()
