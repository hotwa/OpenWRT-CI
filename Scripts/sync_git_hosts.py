#!/usr/bin/env python3
"""Check or fast-forward one branch to both hosts; never overwrite divergence."""
import argparse
import json
import re
import subprocess
import sys
import uuid

class SyncError(RuntimeError):
    pass

def git(*args, missing_ok=False):
    result = subprocess.run(['git', *args], capture_output=True, text=True)
    if result.returncode and not missing_ok:
        raise SyncError('Git operation failed (exit %d); inspect authentication or branch state' % result.returncode)
    return result

def snapshot(remote, branch):
    result = git('ls-remote', '--heads', remote, 'refs/heads/' + branch)
    lines = result.stdout.splitlines()
    if not lines:
        return None
    if len(lines) != 1 or not re.fullmatch(r'[0-9a-f]{40}\trefs/heads/' + re.escape(branch), lines[0]):
        raise SyncError('ambiguous remote branch identity')
    return lines[0].split()[0]

def synchronize(remotes, branch, apply=False, allow_create=False):
    if len(remotes) != 2 or len(set(remotes)) != 2 or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', r) for r in remotes):
        raise SyncError('select two distinct named Git remotes')
    git('check-ref-format', 'refs/heads/' + branch)
    target = git('rev-parse', '--verify', 'refs/heads/' + branch).stdout.strip()
    refs = []
    report = {'branch': branch, 'commit': target, 'mode': 'apply' if apply else 'check', 'remotes': []}
    try:
        # Check both destinations before writing either of them.
        for remote in remotes:
            git('remote', 'get-url', remote)  # Capture only; never print auth-bearing URLs.
            old = snapshot(remote, branch)
            item = {'remote': remote, 'old_commit': old, 'state': 'unchanged' if old == target else 'fast-forward'}
            report['remotes'].append(item)
            if old is None:
                if not allow_create:
                    raise SyncError('remote branch missing; creation requires --allow-create')
                item['state'] = 'create'
                continue
            temporary = 'refs/dual-ci-check/' + uuid.uuid4().hex
            refs.append(temporary)
            git('fetch', '--no-tags', '--no-write-fetch-head', remote,
                'refs/heads/' + branch + ':' + temporary)
            observed = git('rev-parse', temporary).stdout.strip()
            if observed != old:
                raise SyncError('remote changed during inspection; repeat the check')
            if git('merge-base', '--is-ancestor', observed, target, missing_ok=True).returncode:
                raise SyncError('remote has changes absent locally; fetch and merge before synchronizing')
        if apply:
            for item in report['remotes']:
                remote = item['remote']
                if snapshot(remote, branch) != item['old_commit']:
                    raise SyncError('remote changed before push; repeat the check')
                if item['old_commit'] != target:
                    # Plain push refuses non-fast-forward races; no force, tags or deletions.
                    git('push', remote, target + ':refs/heads/' + branch)
                item['state'] = 'verified' if snapshot(remote, branch) == target else 'verification-failed'
                if item['state'] != 'verified':
                    raise SyncError('post-push branch verification failed')
        return report
    except SyncError as exc:
        # A cross-host push is not atomic. Report partial success without a force rollback.
        raise SyncError(json.dumps(dict(report, error=str(exc)), sort_keys=True)) from None
    finally:
        for ref in refs:
            git('update-ref', '-d', ref, missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github', default='github')
    parser.add_argument('--cnb', default='cnb')
    parser.add_argument('--branch', required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--allow-create', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(synchronize([args.github, args.cnb], args.branch, args.apply, args.allow_create), sort_keys=True))
    except SyncError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
