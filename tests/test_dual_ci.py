"""Offline execution parity and synchronization failures; no cloud or device calls."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
import firmware_build as build
import dual_ci_contract as contract
import sync_git_hosts as sync


def test_all_enabled_plans_and_bindings_without_build_or_credentials():
    with patch.object(build.subprocess, 'run', side_effect=AssertionError('must not execute')):
        contract.validate_entries()
        for name in contract.EVENTS.values():
            assert contract.plan(name, 'github') == contract.plan(name, 'cnb')
    with pytest.raises(ValueError):
        contract.plan('cpe5g-a', 'github')


def test_core_drift_stops_both_platforms():
    with patch.object(build, 'CORE_SHA256', '0' * 64):
        for platform in ('github', 'cnb'):
            with pytest.raises(build.BuildGateError):
                contract.plan('re-ss-01', platform)


def test_wrong_cnb_target_and_automatic_build_are_rejected(tmp_path):
    for change in ('target', 'automatic', 'secrets'):
        wf = tmp_path / '.github/workflows/DUAL-PLATFORM-BUILD.yml'
        wf.parent.mkdir(parents=True, exist_ok=True)
        wf.write_text((ROOT / '.github/workflows/DUAL-PLATFORM-BUILD.yml').read_text())
        config = yaml.safe_load((ROOT / '.cnb.yml').read_text())
        if change == 'target':
            # Mutate a new object so the aliased migration entry stays correct.
            entry = json.loads(json.dumps(config['main']['api_trigger_re_build_ss01']))
            for stage in entry[0]['stages']:
                if 'cnb_replay_core.py' in stage.get('script', ''):
                    stage['script'] = stage['script'].replace(' re-ss-01', ' re-cs-07')
            config['main']['api_trigger_re_build_ss01'] = entry
        elif change == 'automatic':
            config['$']['push'] = [{'stages': [{'script': 'python3 Scripts/firmware_build.py re-ss-01'}]}]
        else:
            config['main']['push'] = [{'imports': ['synthetic-build-secrets']}]
        (tmp_path / '.cnb.yml').write_text(yaml.safe_dump(config))
        with patch.object(contract, 'ROOT', tmp_path), pytest.raises(ValueError):
            contract.validate_entries()


def test_missing_credentials_reject_without_value_disclosure():
    for name in contract.EVENTS.values():
        required = build.profile_expectations(build.PROFILES[name])['required_secrets']
        values = {key: 'synthetic-not-a-real-secret' for key in required}
        assert build.secret_env(values, build.PROFILES[name])
        for missing in required:
            bad = dict(values, **{missing: '<FILL_MANUALLY>'})
            with pytest.raises(build.BuildGateError) as error:
                build.secret_env(bad, build.PROFILES[name])
            assert missing in str(error.value)
            assert 'synthetic-not-a-real-secret' not in str(error.value)


@pytest.mark.parametrize('platform', ['github', 'cnb'])
def test_identity_bound_to_real_checkout_and_run(platform):
    sha = 'a' * 40
    env = {'GITHUB_SHA': sha, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2',
           'GITHUB_REPOSITORY': 'hotwa/OpenWRT-CI', 'CNB_BUILD_ID': 'cnb-fixture-001',
           'CNB_COMMIT': sha, 'CNB_REPO_SLUG': 'b2233/openwrt-ci'}
    assert build.build_identity(platform, env, sha)['platform'] == platform
    env['GITHUB_SHA' if platform == 'github' else 'CNB_COMMIT'] = 'b' * 40
    with pytest.raises(build.BuildGateError):
        build.build_identity(platform, env, sha)
    with pytest.raises(build.BuildGateError):
        build.build_identity(platform, {}, sha)


def test_both_hosts_execute_identical_shell_stages_with_sanitized_environment(tmp_path):
    # Run the real orchestration through every stage. Shell, compiler, network,
    # affinity and guard execution are simulated; their commands never run.
    bodies = {}
    for platform in ('github', 'cnb'):
        root = tmp_path / platform
        root.mkdir(); (root / '.git').mkdir()
        inputs = build.profile_inputs('re-ss-01')
        stages = build.workflow_steps()
        names = {stage['run']: name for name, stage in stages.items() if 'run' in stage}
        seen = []
        env = {'PATH': '/usr/bin', 'SAMBA_DEFAULT_PASSWORD': 'fixture-only',
               'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2',
               'GITHUB_REPOSITORY': 'hotwa/OpenWRT-CI', 'CNB_COMMIT': 'a' * 40,
               'CNB_BUILD_ID': 'cnb-fixture-001', 'CNB_REPO_SLUG': 'b2233/openwrt-ci',
               'FIRMWARE_CD_SSH_PRIVATE_KEY': 'MUST-NOT-INHERIT',
               'AGENT_RUNTIME_USIGN_SECRET_KEY': 'MUST-NOT-INHERIT',
               'CNB_TOKEN': 'MUST-NOT-INHERIT', 'GITHUB_TOKEN': 'MUST-NOT-INHERIT'}
        def output(args, **kwargs):
            if args[:3] == ['git', 'rev-parse', 'HEAD']: return 'a' * 40 + '\n'
            if args[:2] == ['git', '-C']: return inputs['WRT_COMMIT'] + '\n'
            if args == ['go', 'version']: return 'go version go1.26.0 linux/amd64\n'
            if args == ['node', '--version']: return 'v24.20.0\n'
            raise AssertionError('unexpected subprocess')
        def execute(args, **kwargs):
            host = kwargs['env']
            assert 'MUST-NOT-INHERIT' not in host.values()
            assert host['GITHUB_REPOSITORY'] == 'hotwa/OpenWRT-CI'
            if 'GuardReCs07Artifact.sh' in args[1]: return
            script = Path(args[-1]).read_text()
            name = names.get(script, 'Reserve Disk Space Before Compile')
            seen.append((name, script))
            handoff = Path(host['GITHUB_ENV'])
            if name == 'Clone Code':
                (root / 'wrt').mkdir()
                handoff.write_text('WRT_HASH=' + inputs['WRT_COMMIT'] + '\n')
            if name == 'Update Feeds':
                (root / 'wrt/tmp').mkdir()
                for file in ('.packageinfo', '.targetinfo'):
                    (root / 'wrt/tmp' / file).write_text('fixture')
            if name == 'Compute Build Cache Identity':
                handoff.write_text('WRT_CACHE_KEY=fixture\nWRT_CACHE_LOOKUP_KEY=fixture\nWRT_CACHE_SAVE_KEY=fixture\nWRT_CACHE_RESTORE_PREFIX=fixture\nWRT_CACHE_IDENTITY_STATUS=passed\n')
            if name == 'Custom Packages and Agent Runtimes':
                handoff.write_text('WRT_PRIVATE_BUILD=true\nWRT_ARTIFACT_PRIVACY_SUFFIX=private\n')
            if name == 'Package Firmware':
                upload = root / 'wrt/upload'; upload.mkdir()
                metadata = {'workflow_commit': 'a' * 40, 'source_commit': inputs['WRT_COMMIT'],
                            'config': inputs['WRT_CONFIG'], 'required_device': inputs['WRT_REQUIRED_DEVICE'],
                            'source_repository': inputs['WRT_REPO']}
                (upload / 'metadata.json').write_text(json.dumps(metadata))
                (upload / 'fixture-sysupgrade.bin').write_bytes(b'NOT-A-FIRMWARE')
                (upload / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in sorted(upload.iterdir())))
        with patch.object(build, 'ROOT', root), patch.object(build, 'profile_inputs', return_value=inputs), patch.dict(os.environ, env, clear=True), \
             patch.object(build, 'pin_github_cpu_count'), \
             patch.object(build.subprocess, 'check_output', side_effect=output), \
             patch.object(build.subprocess, 'run', side_effect=execute):
            build.run('re-ss-01', platform)
        assert [name for name, _ in seen] == list(build.STEPS)
        receipt = json.loads((root / 'wrt/upload/build-receipt.json').read_text())
        assert receipt['platform'] == platform
        assert receipt['workflow_commit'] == 'a' * 40
        assert 'fixture-only' not in json.dumps(receipt)
        assert 'MUST-NOT-INHERIT' not in json.dumps(receipt)
        assert 'build-receipt.json' in (root / 'wrt/upload/SHA256SUMS').read_text()
        bodies[platform] = seen
    assert bodies['github'] == bodies['cnb']


def command(directory, *args):
    return subprocess.check_output(['git', '-C', str(directory), *args], stderr=subprocess.DEVNULL, text=True).strip()

@pytest.fixture
def repositories(tmp_path, monkeypatch):
    local = tmp_path / 'local'; local.mkdir()
    command(local, 'init', '-b', 'main')
    command(local, 'config', 'user.name', 'Fixture')
    command(local, 'config', 'user.email', 'fixture@example.invalid')
    (local / 'configuration').write_text('baseline')
    command(local, 'add', '.'); command(local, 'commit', '-m', 'baseline')
    bare = []
    for host in ('github', 'cnb'):
        dest = tmp_path / host
        command(tmp_path, 'init', '--bare', str(dest))
        command(local, 'remote', 'add', host, str(dest))
        command(local, 'push', host, 'main')
        bare.append(dest)
    monkeypatch.chdir(local)
    return local, bare


def test_sync_check_is_readonly_then_fast_forwards_both(repositories):
    local, bare = repositories
    old = command(local, 'rev-parse', 'main')
    (local / 'configuration').write_text('new settings')
    command(local, 'commit', '-am', 'configuration change')
    new = command(local, 'rev-parse', 'main')
    sync.synchronize(['github', 'cnb'], 'main')
    assert [command(p, 'rev-parse', 'main') for p in bare] == [old, old]
    report = sync.synchronize(['github', 'cnb'], 'main', apply=True)
    assert all(r['state'] == 'verified' for r in report['remotes'])
    assert [command(p, 'rev-parse', 'main') for p in bare] == [new, new]
    assert command(local, 'for-each-ref', 'refs/dual-ci-check') == ''


def test_remote_changes_stop_both_before_writing(repositories, tmp_path):
    local, bare = repositories
    original = command(local, 'rev-parse', 'main')
    other = tmp_path / 'other'
    command(tmp_path, 'clone', '-b', 'main', str(bare[1]), str(other))
    command(other, 'config', 'user.name', 'Other')
    command(other, 'config', 'user.email', 'other@example.invalid')
    (other / 'configuration').write_text('CNB edit')
    command(other, 'commit', '-am', 'CNB change'); command(other, 'push', 'origin', 'main')
    remote_change = command(other, 'rev-parse', 'main')
    (local / 'configuration').write_text('GitHub edit')
    command(local, 'commit', '-am', 'independent change')
    with pytest.raises(sync.SyncError, match='fetch and merge'):
        sync.synchronize(['github', 'cnb'], 'main', apply=True)
    assert command(bare[0], 'rev-parse', 'main') == original
    assert command(bare[1], 'rev-parse', 'main') == remote_change
    assert command(local, 'for-each-ref', 'refs/dual-ci-check') == ''


def test_cnb_real_run_identity_is_compatible_with_legacy_cache_key():
    identity = build.build_identity('cnb', {
        'CNB_BUILD_ID': 'cnb-fixture-001', 'CNB_COMMIT': 'a' * 40,
        'CNB_REPO_SLUG': 'b2233/openwrt-ci'}, 'a' * 40)
    assert identity['run_id'] == 'cnb-fixture-001'
    assert identity['legacy_run_id'].isdigit()
    result = subprocess.run(['bash', str(ROOT / 'Scripts/wrt_cache_lib.sh'), 'keys',
                             'fixture', 'a' * 64, identity['legacy_run_id'], '1'],
                            capture_output=True, text=True)
    assert result.returncode == 0


def test_native_runner_can_use_two_cpus_without_changing_default_four_cpu_gate():
    with patch.dict(os.environ, {'CNB_REPLAY_CPU_PIN': 'native'}), \
         patch.object(build.os, 'sched_getaffinity', return_value={0, 1}), \
         patch.object(build.os, 'sched_setaffinity') as affinity:
        build.pin_github_cpu_count()
        affinity.assert_not_called()
