#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile, textwrap
script=pathlib.Path(sys.argv[1])/'Scripts/verify_commandcode_native.js'
with tempfile.TemporaryDirectory() as td:
    prefix=pathlib.Path(td)
    package=prefix/'lib/node_modules/command-code'
    package.mkdir(parents=True)
    manifest=package/'package.json'
    def write(deps=None, optional=None):
        manifest.write_text(json.dumps({'name':'command-code','version':'fixture','dependencies':deps or {},'optionalDependencies':optional or {}}))
    def run(ok):
        r=subprocess.run(['node',str(script),str(prefix)],capture_output=True,text=True)
        assert (r.returncode==0)==ok, r.stdout+r.stderr
    write();run(True) # Retired backends are not dependencies of current versions.
    write({'@napi-rs/keyring':'1'});run(False)
    write(optional={'zigpty':'1'});run(False) # Declared optional native gate stays strict.
    native=package/'node_modules/@napi-rs/keyring'
    native.mkdir(parents=True)
    (native/'index.js').write_text('module.exports = {};')
    write({'@napi-rs/keyring':'1'});run(True) # Nested npm layout.
    (native/'index.js').write_text('throw new Error("broken native backend");')
    run(False);write();run(False) # Installed but undeclared broken backend also fails.
    manifest.unlink();run(False)
print('CommandCode manifest-aware native probe: 7 fixture cases passed')

# Execute the workflow's actual shell guard with force_release enabled.
# A repair branch must exit before channel downloads or publication decisions.
workflow=(script.parent.parent/'.github/workflows/Agent-Runtime-Bump.yml').read_text()
assert "VERIFY_ONLY: ${{ github.ref != 'refs/heads/main' }}" in workflow
step=workflow.split('      - name: Compare verified latest candidate with stable channel\n',1)[1]
body=textwrap.dedent(step.split('        run: |\n',1)[1].split('\n      - name:',1)[0])
body=body.replace('${{ inputs.force_release }}','true')
with tempfile.TemporaryDirectory() as td:
    output=pathlib.Path(td)/'output'
    env=dict(os.environ,VERIFY_ONLY='true',DRY_RUN='false',GITHUB_OUTPUT=str(output))
    result=subprocess.run(['bash','-eu','-c',body],env=env,capture_output=True,text=True)
    assert result.returncode==0, result.stdout+result.stderr
    assert output.read_text()=='changed=false\n'
    assert 'only main may publish' in result.stdout
print('Runtime branch validation blocks forced stable publication')
PY
