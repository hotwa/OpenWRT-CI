#!/usr/bin/env python3
"""Offline GitHub/CNB firmware contract: no credentials, builds or devices."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

import yaml
import firmware_build as build

ROOT = Path(__file__).resolve().parent.parent
EVENTS = {
    'cs07': 're-cs-07', 'cs02': 're-cs-02', 'ss01': 're-ss-01',
    'wlg': 'wlg-re-cs-07', 'cpe5g': 'cpe5g-b',
    'cpe5g_configonly': 'cpe5g-b-configonly',
    'qca_no': 'qca-ipq60xx-wifi-no', 'qca_yes': 'qca-ipq60xx-wifi-yes',
}

def plan(profile, platform):
    if platform not in ('github', 'cnb') or profile not in EVENTS.values():
        raise ValueError('unsupported platform or enabled profile')
    steps = build.workflow_steps()
    inputs = build.profile_inputs(profile)
    # config-only is a profile identity, not a host-specific accidental flag.
    config_only = profile.endswith('-configonly')
    inputs['WRT_TEST'] = 'true' if config_only else 'false'
    selected = [name for name in build.STEPS
                if not config_only or name not in build.CONFIG_ONLY_SKIPPED]
    digest = lambda data: hashlib.sha256(data).hexdigest()
    configs = ['Config/GENERAL.txt', 'Config/' + inputs['WRT_CONFIG'] + '.txt']
    return {
        'schema_version': 1, 'profile': profile, 'config': inputs['WRT_CONFIG'],
        'source_repository': inputs['WRT_REPO'], 'source_commit': inputs['WRT_COMMIT'],
        'device': inputs['WRT_REQUIRED_DEVICE'], 'config_only': config_only,
        'inputs_sha256': build.inputs_digest(inputs),
        'core_sha256': build.CORE_SHA256, 'legacy_repository': build.LEGACY_REPOSITORY,
        'stages': [{'name': name, 'sha256': digest(steps[name]['run'].encode())}
                   for name in selected],
        'config_sha256': {name: digest((ROOT / name).read_bytes()) for name in configs},
        'secret_names': sorted(build.SENSITIVE),
        'required_secret_names': sorted(build.profile_expectations(build.PROFILES[profile])['required_secrets']),
        'secret_values_read': False, 'deployment': 'disabled',
    }

def validate_entries():
    config = yaml.safe_load((ROOT / '.cnb.yml').read_text())
    branches = [config['migration/cnb-shadow-20260926'], config['main']]
    for branch in branches:
        for suffix, profile in EVENTS.items():
            for family in ('web_trigger', 'api_trigger'):
                entries = branch[family + '_re_build_' + suffix]
                if len(entries) != 1:
                    raise ValueError('single-target event must own one pipeline')
                scripts = [s.get('script', '') for s in entries[0]['stages']]
                command = next((s for s in scripts if 'cnb_replay_core.py' in s), '')
                if not command.endswith(' ' + profile):
                    raise ValueError('CNB event/profile drift')
                if ('CNB_REPLAY_WRT_TEST=1' in command) != profile.endswith('-configonly'):
                    raise ValueError('CNB config-only identity drift')
                if entries != config['migration/cnb-shadow-20260926'][family + '_re_build_' + suffix]:
                    raise ValueError('main and migration build contracts differ')
    wf = yaml.safe_load((ROOT / '.github/workflows/DUAL-PLATFORM-BUILD.yml').read_text())
    trigger = wf.get('on', wf.get(True))
    if set(trigger) != {'workflow_dispatch'}:
        raise ValueError('firmware compiler must remain manually triggered')
    fields = trigger['workflow_dispatch']['inputs']
    if set(fields['profile']['options']) != set(EVENTS.values()) or fields['execute_build']['default'] is not False:
        raise ValueError('GitHub profile list or explicit build opt-in drift')
    job = wf['jobs']['build']
    if job['if'] != '${{ inputs.execute_build }}':
        raise ValueError('GitHub build must require explicit opt-in')
    if set(job['env']) & {'HEADSCALE_CI_AUTHKEY', 'FIRMWARE_CD_SSH_PRIVATE_KEY', 'AGENT_RUNTIME_USIGN_SECRET_KEY'}:
        raise ValueError('build acquired deployment or signing credentials')
    if job.get('needs') != 'contract':
        raise ValueError('GitHub build lost its contract dependency')
    if not set(build.SENSITIVE) <= set(job['env']):
        raise ValueError('GitHub build secret names incomplete')
    if any(job['env'][key] != '${{ secrets.' + key + ' }}' for key in build.SENSITIVE):
        raise ValueError('GitHub build secret binding drift')
    if not any('Scripts/firmware_build.py "$BUILD_PROFILE" --platform github' in s.get('run', '')
               for s in job['steps']):
        raise ValueError('GitHub no longer calls the shared compiler')
    # Push and PR checks must remain credential-free and cannot invoke compilation.
    for key in ('main', '$'):
        for event in ('push', 'pull_request'):
            jobs = config[key][event]
            if any('imports' in j or re.search(r'python3? (?:-u )?Scripts/(?:firmware_build|cnb_replay_core)\.py', str(j)) for j in jobs):
                raise ValueError('automatic check acquired firmware or credential access')
    for value in config['main'].values():
        if re.search(r'\bsysupgrade\b|FirmwareFleetDeploy|env\.cd\.yml', str(value)):
            raise ValueError('dual-platform build acquired deployment')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=sorted(EVENTS.values()))
    args = parser.parse_args()
    try:
        validate_entries()
        profiles = [args.profile] if args.profile else list(EVENTS.values())
        results = []
        for profile in profiles:
            github, cnb = plan(profile, 'github'), plan(profile, 'cnb')
            if github != cnb:
                raise ValueError('platform build plans differ')
            results.append(github)
        print(json.dumps({'status': 'passed', 'profiles': results}, sort_keys=True))
    except (ValueError, OSError, build.BuildGateError, KeyError) as exc:
        print('ERROR: dual-platform contract: ' + str(exc), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
