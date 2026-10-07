#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT
python3 - <<'PY'
import os, pathlib, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
installer = root / 'Scripts/restore_recs02_regulatory_clamp.sh'
patch = root / 'Scripts/patches/990-ath11k-clamp-reg-rule-bandwidth.patch'
with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    recipe = work / 'wrt/package/kernel/mac80211/Makefile'
    recipe.parent.mkdir(parents=True)
    recipe.write_text('PKG_SOURCE_VERSION:=7.2\nPKG_HASH:=6ec76a4cb0988b5382b2fc5053610a56ada90b8ef6a5a4f2807cd433badb9454\n')
    destination = recipe.parent / 'patches/ath11k' / patch.name
    destination.parent.mkdir(parents=True)
    env = dict(os.environ, GITHUB_WORKSPACE=str(work), WRT_DIR='wrt',
               WRT_REQUIRED_DEVICE='jdcloud_re-cs-02',
               WRT_COMMIT='0fb9b10cb9df51fb076470e1dd93d1c30dd89d83')
    def run(expected=0, **changes):
        result = subprocess.run(['bash', str(installer)], env=dict(env, **changes), capture_output=True)
        assert (result.returncode == 0) == (expected == 0), result.stderr.decode()
    run(WRT_REQUIRED_DEVICE='jdcloud_re-ss-01')
    assert not destination.exists(), 'unaffected device was modified'
    run(WRT_COMMIT='a4638cd4389183f1a1fcad0441f491ca11c97757')
    assert not destination.exists(), 'old source was modified'
    run(); assert destination.read_bytes() == patch.read_bytes()
    run(); assert destination.read_bytes() == patch.read_bytes(), 'not idempotent'
    destination.write_text('unreviewed upstream patch\n')
    run(expected=1)
    assert destination.read_text() == 'unreviewed upstream patch\n', 'conflicting patch overwritten'
    destination.unlink()
    recipe.write_text('PKG_SOURCE_VERSION:=7.3\nPKG_HASH:=unknown\n')
    run(expected=1); assert not destination.exists(), 'unreviewed backports accepted'

    # Exact unmodified helper from backports 7.2, before the reviewed patch.
    source = '''static void
ath11k_reg_update_rule(struct ieee80211_reg_rule *reg_rule, u32 start_freq,
\t\t       u32 end_freq, u32 bw, u32 ant_gain, u32 reg_pwr,
\t\t       s8 psd, u32 reg_flags)
{
\treg_rule->freq_range.start_freq_khz = MHZ_TO_KHZ(start_freq);
\treg_rule->freq_range.end_freq_khz = MHZ_TO_KHZ(end_freq);
\treg_rule->freq_range.max_bandwidth_khz = MHZ_TO_KHZ(bw);
\treg_rule->power_rule.max_antenna_gain = DBI_TO_MBI(ant_gain);
\treg_rule->power_rule.max_eirp = DBM_TO_MBM(reg_pwr);
\treg_rule->psd = psd;
\treg_rule->flags = reg_flags;
}
'''
    target = work / 'drivers/net/wireless/ath/ath11k/reg.c'
    target.parent.mkdir(parents=True); target.write_text(source)
    subprocess.run(['patch', '--fuzz=0', '-p1', '-d', str(work), '-i', str(patch)], check=True, capture_output=True)
    header = '''#include <assert.h>
#include <stdint.h>
typedef uint32_t u32; typedef int8_t s8;
#define MHZ_TO_KHZ(x) ((x) * 1000)
#define DBI_TO_MBI(x) ((x) * 100)
#define DBM_TO_MBM(x) ((x) * 100)
#define min_t(t,a,b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
struct ieee80211_reg_rule {
 struct { u32 start_freq_khz,end_freq_khz,max_bandwidth_khz; } freq_range;
 struct { u32 max_antenna_gain,max_eirp; } power_rule;
 s8 psd; u32 flags;
};
'''
    harness = '''int main(void) {
 struct ieee80211_reg_rule r;
 ath11k_reg_update_rule(&r, 5735, 5835, 160, 6, 30, -1, 0x42);
 assert(r.freq_range.max_bandwidth_khz == 100000);
 assert(r.freq_range.start_freq_khz == 5735000 && r.freq_range.end_freq_khz == 5835000);
 assert(r.power_rule.max_antenna_gain == 600 && r.power_rule.max_eirp == 3000);
 assert(r.psd == -1 && r.flags == 0x42);
 ath11k_reg_update_rule(&r, 5170, 5250, 80, 6, 30, 0, 0);
 assert(r.freq_range.max_bandwidth_khz == 80000);
 ath11k_reg_update_rule(&r, 5170, 5250, 20, 6, 30, 0, 0);
 assert(r.freq_range.max_bandwidth_khz == 20000);
 ath11k_reg_update_rule(&r, 5250, 5250, 80, 6, 30, 0, 0);
 assert(r.freq_range.max_bandwidth_khz == 0);
 ath11k_reg_update_rule(&r, 5250, 5170, 80, 6, 30, 0, 0);
 assert(r.freq_range.max_bandwidth_khz == 0 && r.freq_range.start_freq_khz > r.freq_range.end_freq_khz);
 return 0;
}
'''
    c = work / 'probe.c'; c.write_text(header + target.read_text() + harness)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(work/'probe')], check=True)
    subprocess.run([str(work/'probe')], check=True)
print('PASS: device/source scope, idempotency, conflict/drift rejection and patched C bandwidth/power invariants')
PY
