#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run the actual 20 -> 21 -> 99 profile order in disposable paths. The uv
# child must receive the boot-selected paths before the late profile exports.
python3 - "$ROOT_DIR" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="uv-python-profile-") as temporary:
    base = Path(temporary)
    for name, state, storage, usable, mode in (
        ("persistent", "persistent", "/data", True, "file"),
        ("fallback", "fallback", "/root", True, "file"),
        ("emergency", "emergency", "/tmp", False, "file"),
        ("invalid-state", "unknown", "/data", False, "file"),
        ("invalid-root", "persistent", "/opt", False, "file"),
        ("missing-state", "", "", False, "file"),
        ("missing-env", "persistent", "/data", False, "missing"),
        ("symlink-env", "persistent", "/data", False, "symlink"),
    ):
        case = base / name
        case.mkdir()
        mapping = {p: str(case / p.lstrip('/')) for p in ("/var/run", "/data", "/opt", "/root", "/tmp")}
        def rooted(text):
            # A single pass avoids remapping the fixture's own /tmp prefix.
            return re.sub(r'/var/run(?![\w.-])|/(?:data|opt|root|tmp)(?![\w.-])', lambda m: mapping[m[0]], text)

        profiles = {}
        for profile in ("20-node-agent.sh", "21-uv-python.sh", "99-data-runtime.sh"):
            target = case / profile
            target.write_text(rooted((repo / "files/etc/profile.d" / profile).read_text()))
            profiles[profile] = target
        run = case / "var/run"
        run.mkdir(parents=True)
        cache = rooted("/data/cache/uv" if storage == "/data" else "/root/.cache/uv")
        tools = rooted("/data/uv/tools" if storage == "/data" else "/root/.local/share/uv/tools")
        install = rooted("/data/uv/python" if storage == "/data" else "/root/.local/share/uv/python")
        content = f'DATA_RUNTIME_STATE={state}\nDATA_RUNTIME_ROOT={rooted(storage)}\nUV_CACHE_DIR={cache}\nUV_TOOL_DIR={tools}\nUV_PYTHON_INSTALL_DIR={install}\n'
        runtime_env = run / "data-runtime.env"
        if mode == "file":
            runtime_env.write_text(content)
        elif mode == "symlink":
            backing = run / "backing.env"
            backing.write_text(content)
            runtime_env.symlink_to(backing)

        python = Path(install) / "cpython-fixture/bin/python3"
        python.parent.mkdir(parents=True)
        python.write_text('#!/bin/sh\nprintf "fixture Python 3.13\\n"\n')
        python.chmod(0o755)
        for uv_root in (case / "opt/uv", case / "data/agent-runtime/current/uv"):
            uv_root.mkdir(parents=True)
            uv = uv_root / "uv"
            uv.write_text('''#!/bin/sh
printf '%s|%s|%s|%s\n' "${UV_CACHE_DIR-unset}" "${UV_TOOL_DIR-unset}" "${UV_PYTHON_INSTALL_DIR-unset}" "$*" >> "$UV_PROFILE_CALLS"
[ "${UV_CACHE_DIR-unset}" = "$EXPECTED_UV_CACHE" ] && [ "${UV_TOOL_DIR-unset}" = "$EXPECTED_UV_TOOLS" ] && [ "${UV_PYTHON_INSTALL_DIR-unset}" = "$EXPECTED_UV_INSTALL" ] || exit 1
[ "$1 $2" = 'python find' ] || exit 1
printf '%s/cpython-fixture/bin/python3\n' "$UV_PYTHON_INSTALL_DIR"
''')
            uv.chmod(0o755)
        calls = case / "uv.calls"
        # Inherited host UV/data selections must not contaminate the fixture.
        env = {k: v for k, v in os.environ.items() if not k.startswith(("UV_", "DATA_RUNTIME_"))}
        env.update(PATH="/usr/bin:/bin", UV_PROFILE_CALLS=str(calls), EXPECTED_UV_CACHE=cache,
                   EXPECTED_UV_TOOLS=tools, EXPECTED_UV_INSTALL=install)
        script = '''. "$1"
. "$2"
printf 'early-python=%s\n' "$(command -v python3 || true)"
printf 'early-install=%s\n' "${UV_PYTHON_INSTALL_DIR-unset}"
. "$3"
printf 'late-python=%s\n' "$(command -v python3 || true)"
'''
        result = subprocess.run(['sh', '-c', script, 'profile-fixture', *map(str, profiles.values())],
                                env=env, text=True, capture_output=True, check=True)
        records = dict(line.split('=', 1) for line in result.stdout.splitlines())
        if usable:
            assert records['early-python'] == str(python), (name, result.stdout)
            assert records['late-python'] == str(python), (name, result.stdout)
            assert records['early-install'] == install
            assert calls.read_text().splitlines() == [f'{cache}|{tools}|{install}|python find 3.13']
        else:
            assert records['early-python'] != str(python), (name, result.stdout)
            assert records['late-python'] != str(python), (name, result.stdout)
            assert records['early-install'] == 'unset', (name, result.stdout)
            assert not calls.exists(), name + ' must skip unselected interpreter discovery'
print('uv Python login profile ordering and missing/invalid storage cases passed')
PY
