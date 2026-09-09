#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# No downloads or real firmware builds: parse the policy and execute the actual
# workflow's two container conditionals in isolated staging trees with a fetch
# stub. The outer feature-overlay gate is deliberately not changed by this test.
python3 - "$ROOT_DIR" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        # Ubuntu 22.04 may have Python 3.10 with pip's bundled TOML reader.
        from pip._vendor import tomli as tomllib

root = Path(sys.argv[1])
overlay = root / "files-container-runtime-test"
relative = Path("etc/containerd/certs.d/docker.io/hosts.toml")
policy = tomllib.loads((overlay / relative).read_text())
official = "https://registry-1.docker.io"
mirror = "https://dockerproxy.net"
# containerd parseHostsFile appends the root server AFTER ordered host tables;
# root hostFileConfig includes capabilities. Do not accidentally append an
# unrestricted server or move the official endpoint behind the mirror.
# Source: containerd v2.1.4 core/remotes/docker/config/hosts.go, parseHostsFile.
assert set(policy) == {"server", "capabilities", "host"}, policy
assert policy["server"] == mirror
assert list(policy["host"]) == [official]
assert policy["capabilities"] == ["pull", "resolve"]
assert policy["host"][official] == {"capabilities": ["pull", "resolve"]}
effective = list(policy["host"]) + [policy["server"]]
assert effective == [official, mirror]
daemon = tomllib.loads((overlay / "etc/containerd/containerd-test.toml").read_text())
assert "registry" not in daemon, "registry policy belongs to hosts.toml, not daemon top-level"
assert not (root / "files" / relative).exists(), "registry policy leaked into ungated overlay"
for name in ("containerd-test", "container-bridge-nft"):
    assert not (root / "files/etc/init.d" / name).exists(), "service leaked into base overlay"
for path in ("etc/config/containerd-test", "usr/sbin/container-bridge-nft",
             "etc/uci-defaults/97-containerd-test-enable", "etc/containerd/containerd-test.toml"):
    assert not (root / "files" / path).exists(), f"runtime config leaked into base overlay: {path}"
assert not (overlay / "etc/init.d/compose-apps").exists(), "no compose boot daemon"
assert not list(overlay.rglob("compose.yaml")), "do not preinstall a compose workload"
assert not list(overlay.rglob("docker-compose.yml")), "do not preinstall a compose workload"

workflow = (root / ".github/workflows/WRT-CORE.yml").read_text()
step = workflow.split("      - name: Custom Packages and Agent Runtimes\n", 1)[1]
step = step.split("\n      - name:", 1)[0]
lines = step.split("        run: |\n", 1)[1].splitlines()
lines = [line[10:] if line.startswith(" " * 10) else line for line in lines]
condition = 'if [ "${WRT_CONTAINER_RUNTIME_TEST:-false}" = "true" ]; then'
blocks = []
for i, line in enumerate(lines):
    if line.strip() != condition:
        continue
    indent = line[:len(line) - len(line.lstrip())]
    end = next(j for j in range(i + 1, len(lines)) if lines[j] == indent + "fi")
    blocks.append("\n".join(lines[i:end + 1]))
assert len(blocks) == 2, "review changed container runtime staging gates"
script = "set -euo pipefail\n" + "\n".join(blocks) + "\n"
assert "fetch_container_runtime.sh" in blocks[0]
assert "files-container-runtime-test/. ./wrt/files/" in blocks[1]

for enabled, device, expected_ok in (("false", "unsupported", True),
                                     ("true", "jdcloud_re-ss-01", True),
                                     ("true", "jdcloud_re-cs-02", True),
                                     ("true", "jdcloud_re-cs-07", True),
                                     ("true", "unsupported", False)):
    with tempfile.TemporaryDirectory(prefix="container-gate-") as td:
        stage = Path(td)
        (stage / "wrt/files").mkdir(parents=True)
        shutil.copytree(overlay, stage / "files-container-runtime-test")
        (stage / "Scripts").mkdir()
        stub = stage / "Scripts/fetch_container_runtime.sh"
        stub.write_text('#!/bin/sh\nset -eu\nmkdir -p "$1/usr/bin"\n'
                        'printf "fixture-only\\n" > "$1/usr/bin/containerd"\n'
                        'chmod +x "$1/usr/bin/containerd"\n')
        stub.chmod(0o755)
        # Keep the workflow's Git executable-bit checks meaningful without
        # creating a fixture repository or changing the real worktree/index.
        mockbin = stage / "mockbin"
        mockbin.mkdir()
        git = mockbin / "git"
        git.write_text('#!/bin/sh\nexec /usr/bin/git -C "$SOURCE_REPO" "$@"\n')
        git.chmod(0o755)
        env = dict(os.environ, GITHUB_WORKSPACE=str(stage),
                   GITHUB_ENV=str(stage / "github-env"), SOURCE_REPO=str(root),
                   PATH=str(mockbin) + os.pathsep + os.environ["PATH"],
                   WRT_CONTAINER_RUNTIME_TEST=enabled,
                   WRT_CONTAINER_RUNTIME_MODE="prebuilt", WRT_EXPECTED_DEVICE=device)
        result = subprocess.run(["bash", "-c", script], cwd=stage, env=env,
                                text=True, capture_output=True)
        assert (result.returncode == 0) == expected_ok, result.stdout + result.stderr
        dest = stage / "wrt/files"
        if enabled == "true" and expected_ok:
            assert (dest / relative).read_bytes() == (overlay / relative).read_bytes()
            assert (dest / "etc/config/containerd-test").read_bytes() == (overlay / "etc/config/containerd-test").read_bytes()
            assert "option run_without_bridge '0'" in (dest / "etc/config/containerd-test").read_text()
            for path in ("etc/init.d/containerd-test", "etc/uci-defaults/97-containerd-test-enable",
                         "usr/bin/containerd", "usr/sbin/container-bridge-nft"):
                assert os.access(dest / path, os.X_OK), path
            assert "WRT_CONTAINER_RUNTIME_RESOLVED_MODE=prebuilt" in (stage / "github-env").read_text()
        else:
            assert not list(dest.rglob("*")), "disabled/rejected gate staged runtime files"
            assert not (stage / "github-env").exists()
print("Container registry TOML and isolated false/true staging gates passed (not firmware validation)")
PY
