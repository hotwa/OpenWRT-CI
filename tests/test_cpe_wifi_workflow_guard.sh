#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import os, subprocess, sys, tempfile, textwrap
root=Path(sys.argv[1])
core=(root/'.github/workflows/WRT-CORE.yml').read_text()
input_guard=textwrap.dedent(core.split('      - name: Guard CPE WiFi Inputs\n',1)[1].split('        run: |\n',1)[1].split('\n      - name:',1)[0])
config_guard=textwrap.dedent(core.split('          make defconfig -j$(nproc)\n',1)[1].split('          # zram-swap',1)[0])
base={**os.environ,'WRT_CPE_WIFI':'true','WRT_CPE_5G':'true','WRT_FEATURE_OVERLAY':'true','WRT_ENCRYPT_ARTIFACT':'true','WRT_REQUIRED_DEVICE':'jdcloud_re-ss-01','WRT_CONFIG':'IPQ60XX-706-WIFI'}
cases=0
def check(script,env,ok,cwd):
 global cases
 r=subprocess.run(['bash','-e','-c',script],env=env,cwd=cwd,capture_output=True,text=True)
 assert (r.returncode==0)==ok, 'unexpected WiFi workflow guard result: '+r.stderr
 cases+=1
with tempfile.TemporaryDirectory(prefix='cpe-wifi-guard-') as name:
 cwd=Path(name)
 check(input_guard,base,True,cwd)
 for k in ['WRT_CPE_5G','WRT_FEATURE_OVERLAY','WRT_ENCRYPT_ARTIFACT']:
  check(input_guard,{**base,k:'false'},False,cwd)
 check(input_guard,{**base,'WRT_REQUIRED_DEVICE':'jdcloud_re-cs-02'},False,cwd)
 check(input_guard,{**base,'WRT_CONFIG':'IPQ60XX-706-NOWIFI'},False,cwd)
 check(input_guard,{**base,'WRT_CPE_WIFI':'false','WRT_CONFIG':'unrelated','WRT_CPE_5G':'false'},True,cwd)
 config=(root/'Config/IPQ60XX-706-WIFI.txt').read_text()
 uc=cwd/'package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc';uc.parent.mkdir(parents=True)
 dts=cwd/'target/linux/qualcommax/dts/ipq6000-re-ss-01.dts';dts.parent.mkdir(parents=True)
 def reset():
  (cwd/'.config').write_text(config)
  uc.write_text("set ${si}.disabled='1'\n")
  dts.write_text('#include "ipq6018.dtsi"\n')
 reset(); check(config_guard,base,True,cwd)
 for package in ['kmod-ath11k-ahb','ath11k-firmware-ipq6018-ddwrt','ipq-wifi-jdcloud_re-ss-01','wpad-openssl','wifi-scripts']:
  reset();(cwd/'.config').write_text(config.replace('CONFIG_PACKAGE_'+package+'=y\n',''))
  check(config_guard,base,False,cwd)
 reset();(cwd/'.config').write_text(config+'\nCONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y\n');check(config_guard,base,False,cwd)
 reset();(cwd/'.config').write_text(config+'\nCONFIG_ATH11K_NSS_SUPPORT=y\n');check(config_guard,base,False,cwd)
 reset();dts.write_text('#include "ipq6018-nowifi.dtsi"\n');check(config_guard,base,False,cwd)
 reset();uc.write_text("set ${si}.disabled='0'\n");check(config_guard,base,False,cwd)
 (cwd/'.config').unlink();uc.unlink();dts.unlink();check(config_guard,{**base,'WRT_CPE_WIFI':'false'},True,cwd)
print('CPE WiFi workflow input/package/default-AP gates: %d fixtures passed'%cases)
PY
