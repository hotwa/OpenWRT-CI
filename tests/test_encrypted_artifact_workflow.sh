#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
import ast
import itertools
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
core = (root / '.github/workflows/WRT-CORE.yml').read_text()
cpe = (root / '.github/workflows/CPE-5G.yml').read_text()

def mapping(text, key, indent):
    match = re.search(r'^' + ' ' * indent + re.escape(key) + r':\s*$', text, re.M)
    assert match, f'missing mapping {key}'
    selected = []
    for line in text[match.end():].splitlines():
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        selected.append(line)
    return '\n'.join(selected)

input_block = mapping(core, 'WRT_ENCRYPT_ARTIFACT', 6)
assert 'type: boolean' in input_block and 'default: false' in input_block
assert 'WRT_ENCRYPT_ARTIFACT: ' + chr(36) + '{{inputs.WRT_ENCRYPT_ARTIFACT}}' in mapping(core, 'env', 0)
assert len(re.findall(r'^      WRT_ENCRYPT_ARTIFACT:\s*$', core, re.M)) == 1
assert 'WRT_ENCRYPT_ARTIFACT: true' in mapping(cpe, 'cpe_overlay_b', 2)
assert 'WRT_ENCRYPT_ARTIFACT: true' in mapping(cpe, 'baseline_a', 2)
for workflow in (root / '.github/workflows').glob('*.yml'):
    if workflow.name not in ('WRT-CORE.yml', 'CPE-5G.yml'):
        assert not re.search(r'^\s*WRT_ENCRYPT_ARTIFACT:\s*true\s*$', workflow.read_text(), re.M), workflow.name

step_marks = list(re.finditer(r'^      - name: (.+)$', core, re.M))
steps = {}
order = []
for i, mark in enumerate(step_marks):
    end = step_marks[i + 1].start() if i + 1 < len(step_marks) else len(core)
    name = mark.group(1)
    assert name not in steps, f'duplicate step {name}'
    steps[name] = core[mark.start():end]
    order.append(name)

def condition(block, indent=8):
    match = re.search(r'^' + ' ' * indent + r'if: (.+)$', block, re.M)
    assert match, 'missing step/job condition'
    return match.group(1)

encrypt = steps['Encrypt Firmware Artifact']
encrypted_upload = steps['Upload Encrypted Firmware Artifact']
assert condition(encrypt) == 'inputs.WRT_ENCRYPT_ARTIFACT == true'
assert condition(encrypted_upload) == 'inputs.WRT_ENCRYPT_ARTIFACT == true'
assert 'secrets.' not in encrypt and 'WRT_PRIVATE_BUILD' not in condition(encrypt)
assert 'set -euo pipefail' in encrypt
assert 'unset CPE5G_ARTIFACT_TEST_ALLOW_MISSING_SUMS' in encrypt
assert re.search(r'if \[\[ "\$WRT_TEST" == true \]\]; then\s+export CPE5G_ARTIFACT_TEST_ALLOW_MISSING_SUMS=1\s+fi', encrypt)
assert core.count('export CPE5G_ARTIFACT_TEST_ALLOW_MISSING_SUMS=1') == 1
for argument in (
    '"$GITHUB_WORKSPACE/Scripts/FetchAge.sh" "$RUNNER_TEMP/cpe-age"',
    '"$GITHUB_WORKSPACE/Scripts/EncryptFirmwareArtifact.sh"',
    '"$RUNNER_TEMP/cpe-age/age"',
    '"$GITHUB_WORKSPACE/wrt/upload"',
    '"$GITHUB_WORKSPACE/Config/cpe5g-artifact-recipient.pub"',
    '"$GITHUB_WORKSPACE/wrt/encrypted-upload"',
):
    assert argument in encrypt, f'missing encryption argument {argument}'
assert encrypt.index('Scripts/FetchAge.sh') < encrypt.index('Scripts/EncryptFirmwareArtifact.sh')
assert order.index('Package Firmware') < order.index('Encrypt Firmware Artifact') < order.index('Upload Encrypted Firmware Artifact')
assert re.search(r'name: .+-private-encrypted$', encrypted_upload, re.M)
for setting in ('path: ./wrt/encrypted-upload/', 'compression-level: 0', 'if-no-files-found: error'):
    assert setting in encrypted_upload, f'missing encrypted upload setting {setting}'
assert 'path: ./wrt/upload/' not in encrypted_upload

plain_uploads = {
    name: block for name, block in steps.items()
    if 'uses: actions/upload-artifact@' in block and name != 'Upload Encrypted Firmware Artifact'
}
assert set(plain_uploads) == {
    'Upload Immutable Public Release Input', 'Upload Firmware Artifact',
    'Upload jdcloud_re-ss-01 Firmware Artifact', 'Upload jdcloud_re-cs-02 Firmware Artifact',
    'Upload jdcloud_re-cs-07 Firmware Artifact', 'Upload Other Device Firmware Artifact',
}, 'review any new artifact uploader for encrypted payload leakage'
split_condition = condition(steps['Split Public Firmware Artifacts By Device'])
contract_condition = condition(steps['Define Public Release Input'])
release_condition = condition(mapping(core, 'release', 2), 4)
for guard in [split_condition, contract_condition, release_condition, *(condition(b) for b in plain_uploads.values())]:
    assert 'inputs.WRT_ENCRYPT_ARTIFACT != true' in guard, 'plaintext boundary lacks explicit encryption exclusion'

# Evaluate actual GHA conditions for privacy, TEST, build-only and split.
# Encrypted modes block plaintext even with stale release eligibility.
def evaluate(expression, values):
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'\b(?:inputs|env|steps|needs)\.[A-Za-z0-9_.]+',
                        lambda m: m.group(0).replace('.', '_'), expression)
    expression = re.sub(r"(?<![A-Za-z0-9_'\"])(true|false)(?![A-Za-z0-9_'\"])",
                        lambda m: 'True' if m.group(1) == 'true' else 'False', expression)
    tree = ast.parse(expression.strip(), mode='eval')
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.Compare,
               ast.Eq, ast.NotEq, ast.Name, ast.Load, ast.Constant)
    assert all(isinstance(node, allowed) for node in ast.walk(tree)), 'unsupported workflow guard'
    return eval(compile(tree, '<workflow guard>', 'eval'), {'__builtins__': {}}, values)

for encrypted, private, test, build_only, split in itertools.product((False, True), repeat=5):
    values = {
        'inputs_WRT_ENCRYPT_ARTIFACT': encrypted,
        'inputs_WRT_SPLIT_DEVICE_ARTIFACTS': split,
        'env_WRT_PRIVATE_BUILD': str(private).lower(),
        'env_WRT_TEST': str(test).lower(),
        'env_WRT_BUILD_ONLY': str(build_only).lower(),
        'steps_release_contract_outputs_eligible': 'true',
        'needs_build_outputs_release_eligible': 'true',
    }
    assert evaluate(condition(encrypt), values) is encrypted
    assert evaluate(condition(encrypted_upload), values) is encrypted
    if encrypted:
        assert not evaluate(split_condition, values)
        assert not evaluate(contract_condition, values)
        assert not evaluate(release_condition, values)
        assert not any(evaluate(condition(block), values) for block in plain_uploads.values())
    else:
        public = not (private or test or build_only)
        assert evaluate(split_condition, values) == (split and public)
        assert evaluate(contract_condition, values) == public
        assert evaluate(condition(steps['Upload Firmware Artifact']), values) == (not split or not public)
        for name, block in plain_uploads.items():
            if name not in ('Upload Firmware Artifact', 'Upload Immutable Public Release Input'):
                assert evaluate(condition(block), values) == (split and public)
        assert evaluate(release_condition, values)
        assert evaluate(condition(steps['Upload Immutable Public Release Input']), values)

# Encryption must not alter the credential detection classification.
assert "WRT_PRIVATE_BUILD: 'false'" in core
assert "echo 'WRT_PRIVATE_BUILD=true'" in core
assert "echo 'WRT_PRIVATE_BUILD_REASON=samba-default-credential'" in core
print('encrypted artifact workflow boundaries passed (32 delivery combinations)')
PY
