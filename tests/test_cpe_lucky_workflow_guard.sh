#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
core = (root / '.github/workflows/WRT-CORE.yml').read_text()
cpe = (root / '.github/workflows/CPE-5G.yml').read_text()
general = (root / 'Config/GENERAL.txt').read_text()
bundle_names = tuple(f'CPE_LUCKY_REMOTE_BUNDLE_{number}' for number in range(1, 7))


def field(text, key, indent):
    """Select one explicit field in the repository's block-style YAML."""
    matches = list(re.finditer(r'^' + ' ' * indent + re.escape(key) + r':([^\n]*)$', text, re.M))
    assert len(matches) == 1, f'expected exactly one {key} field at indent {indent}'
    match = matches[0]
    end = len(text)
    for line in re.finditer(r'^.*$', text[match.end():], re.M):
        value = line.group(0)
        if value.strip() and len(value) - len(value.lstrip()) <= indent:
            end = match.end() + line.start()
            break
    return match.group(1).strip(), text[match.end():end], text[match.start():end]


def mapping(text, key, indent):
    value, body, _ = field(text, key, indent)
    assert not value, f'{key} must be an explicit mapping'
    return body


def scalar(text, key, indent):
    value, body, _ = field(text, key, indent)
    assert not body.strip(), f'{key} must be a scalar'
    return value


def workflow_steps(text):
    marks = list(re.finditer(r'^      - name: (.+)$', text, re.M))
    steps = {}
    for index, mark in enumerate(marks):
        name = mark.group(1)
        assert name not in steps, f'duplicate workflow step {name}'
        end = marks[index + 1].start() if index + 1 < len(marks) else len(text)
        steps[name] = text[mark.start():end]
    return steps


workflow_call = mapping(core, 'workflow_call', 2)
call_secrets = mapping(workflow_call, 'secrets', 4)
global_env = mapping(core, 'env', 0)
steps = workflow_steps(core)
smoke = steps['Repository Smoke Tests']
assert 'case "$test_file" in' in smoke, 'privileged fixtures require a scoped suite selector'
assert './tests/test_cpe_public_management.sh|./tests/test_cpe_quota_ledger.sh)' in smoke, 'only the two root-owner suites should be elevated'
assert 'sudo -n env "PATH=$PATH" bash "$test_file"' in smoke, \
    'root-owner fixtures must run as root with the selected Node runtime'
assert '*) bash "$test_file" ;;' in smoke, 'ordinary suites must retain the unprivileged runner'
assert len(re.findall(r'\bsudo\b', smoke)) == 1, 'root privileges escaped the dedicated fixture suite'
private_name = 'Inject Private Firmware Configuration'
assert private_name in steps, 'private firmware injection step is missing'
private = steps[private_name]
assert scalar(private, 'if', 8) == 'inputs.WRT_FEATURE_OVERLAY == true', \
    'Lucky credentials must remain inside the feature-overlay injection gate'
private_env = mapping(private, 'env', 8)
private_run_value, private_run, _ = field(private, 'run', 8)
assert private_run_value == '|', 'private injection must use a literal shell block'

loop = re.search(r'for credential_name in\s+(.+?);\s*do\b.*?\bdone\b', private_run, re.S)
assert loop, 'private credential classification loop is missing'
loop_names = re.findall(r'\b[A-Z][A-Z0-9_]*\b', loop.group(1))
assert '[ -z "${!credential_name:-}" ] || credential_supplied=true' in loop.group(0), \
    'supplied Lucky credentials must classify the firmware as private'

configure_pattern = (
    r'(?:bash\s+)?"?\$GITHUB_WORKSPACE/Scripts/ConfigureCpeLuckyRemote\.sh"?'
    r'\s+"\$GITHUB_WORKSPACE/wrt/files"\s+"\$\{WRT_CPE_5G:-false\}"'
)
assert len(re.findall(configure_pattern, core)) == 1, \
    'Lucky configuration must have exactly one injection call'
configure = re.search(configure_pattern, private_run)
assert configure, 'Lucky generator must receive the firmware overlay and CPE-only enable flag'
guard = private_run.find('Scripts/PrivateFirmwareGuard.sh')
assert guard >= 0 and loop.end() < configure.start() < guard, \
    'credential classification and Lucky generation must precede PrivateFirmwareGuard'
assert 'if [ "$credential_supplied" = true ]; then' in private_run[guard:], \
    'private classification must verify injected credentials after the guard'
assert "grep -qx 'WRT_PRIVATE_BUILD=true'" in private_run[guard:], \
    'Lucky credential injection must be rejected if private classification is lost'

outside_private = core.replace(private, '', 1)
_, _, declaration_scope = field(workflow_call, 'secrets', 4)
outside_private = outside_private.replace(declaration_scope, '', 1)
_, _, private_env_scope = field(private, 'env', 8)
private_unapproved = private.replace(private_env_scope, '', 1).replace(loop.group(0), '', 1)

assert set(re.findall(r'\bCPE_LUCKY_REMOTE_BUNDLE_\d+\b', core)) == set(bundle_names), \
    'core must expose exactly six Lucky bundle slots'
for name in bundle_names:
    declaration = mapping(call_secrets, name, 6)
    assert scalar(declaration, 'required', 8) == 'false', f'{name} must remain optional'
    expression = scalar(private_env, name, 10)
    assert re.fullmatch(r'\$\{\{\s*secrets\.' + re.escape(name) + r'\s*\}\}', expression), \
        f'{name} must come from its matching step-scoped secret'
    assert loop_names.count(name) == 1, f'{name} is missing from private credential classification'
    assert name not in global_env and name not in outside_private, \
        f'{name} escaped workflow_call declarations or private injection'
    assert name not in private_unapproved, f'{name} is referenced outside approved env/classification scopes'

jobs = mapping(cpe, 'jobs', 0)
baseline_a = mapping(jobs, 'baseline_a', 2)
overlay_b = mapping(jobs, 'cpe_overlay_b', 2)
b_secrets = mapping(overlay_b, 'secrets', 4)
b_with = mapping(overlay_b, 'with', 4)
a_with = mapping(baseline_a, 'with', 4)
assert scalar(b_with, 'WRT_CPE_5G', 6) == 'true', 'Lucky bundles require the CPE B feature preset'
assert scalar(b_with, 'WRT_FEATURE_OVERLAY', 6) == 'true', 'CPE B must apply its guarded overlay'
assert scalar(b_with, 'WRT_ENCRYPT_ARTIFACT', 6) == 'true', 'CPE B private Lucky firmware must stay encrypted'
for name in bundle_names:
    expression = scalar(b_secrets, name, 6)
    assert re.fullmatch(r'\$\{\{\s*secrets\.' + re.escape(name) + r'\s*\}\}', expression), \
        f'CPE B must explicitly pass through its matching {name}'
    assert name not in cpe.replace(overlay_b, '', 1), f'{name} must only enter the CPE B caller'

_, b_packages, _ = field(b_with, 'WRT_PACKAGE', 6)
assert len(re.findall(r'^\s*CONFIG_PACKAGE_haproxy=y\s*$', b_packages, re.M)) == 1, \
    'CPE B must include haproxy exactly once in its device-only package override'
assert 'CONFIG_PACKAGE_haproxy' not in baseline_a, 'CPE A must not include the Lucky relay package'
assert scalar(a_with, 'WRT_CPE_5G', 6) == 'false', 'CPE A must retain its isolation preset'
assert scalar(a_with, 'WRT_FEATURE_OVERLAY', 6) == 'false', 'CPE A must not inject private Lucky bundles'
assert 'CONFIG_PACKAGE_haproxy' not in general, 'GENERAL must not enable the CPE-only relay package'
assert not any(name in general for name in bundle_names), 'Lucky bundles must not enter GENERAL'
assert 'CONFIG_PACKAGE_haproxy' not in cpe.replace(overlay_b, '', 1), \
    'haproxy must only enter the CPE B caller'

for workflow in (root / '.github/workflows').glob('*.yml'):
    if workflow.name in ('WRT-CORE.yml', 'CPE-5G.yml'):
        continue
    text = workflow.read_text()
    assert not any(name in text for name in bundle_names), f'Lucky credentials escaped into {workflow.name}'
    assert 'CONFIG_PACKAGE_haproxy' not in text, f'CPE-only haproxy escaped into {workflow.name}'

print('CPE Lucky workflow scope and private artifact guards passed')
PY
