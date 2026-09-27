#!/usr/bin/env python3
"""Build-only CNB adapter: replay reviewed WRT-CORE run steps, not its actions.

This does not emulate checkout/cache/upload/release/debug SSH. Those remain
separate platform gates. Only explicitly whitelisted build steps are executed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

import yaml

from cnb_re_profile_preflight import PROFILES, ROOT, verify_profile

CORE = ROOT / ".github/workflows/WRT-CORE.yml"
# This digest locks the replayed shell bodies. A changed GitHub core must be
# reviewed and this lock deliberately refreshed before any private CNB build.
CORE_SHA256 = "670ee3aea55f3953d9ec815ed1dae560c8f2ced03399ffa10d81c20d351aa3e8"
HOST_PATH = "/opt/cnb-openwrt-host/go/bin:/opt/cnb-openwrt-host/node-v24.20.0-linux-x64/bin"
STEPS = (
    "Validate LAN IP",
    "Initialization Values",
    "Configure Go Module Access",
    "Clone Code",
    "Check Scripts",
    "Repository Smoke Tests",
    "Compute Build Cache Identity",
    "Log Cache Restore Result",
    "Refresh the cache",
    "Update Feeds",
    "Record Go Cache Path Evidence",
    "Custom Packages and Agent Runtimes",
    "Inject Private Firmware Configuration",
    "Guard Firmware Overlay Exclusions",
    "Custom Settings",
    "Guard Expected Device Config",
    "Download Packages",
    "Reserve Disk Space Before Compile",
    "Compile Firmware",
    "Record Compile Cache Stats",
    "Machine Information",
    "Package Firmware",
)
ALLOWED_OUTPUT = re.compile(r"^(?:WRT_[A-Z0-9_]+|GOPROXY|GOSUMDB|GO_INSTALLED)$")
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
SENSITIVE = (
    "SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY", "MULTICA_TOKEN",
    "MULTICA_SERVER_URL", "MULTICA_APP_URL", "MULTICA_WORKSPACE_ID",
    "NIKKI_SUBSCRIPTION_URL", "OPENWRT_DROPBEAR_AUTHORIZED_KEYS",
    "OPENWRT_WAN_PPPOE_USERNAME", "OPENWRT_WAN_PPPOE_PASSWORD",
    "COMMANDCODE_API_KEY", "CLIPROXYAPI_API_KEY", "CLIPROXYAPI_BASE_URL",
)


class BuildGateError(RuntimeError):
    pass


def workflow_steps():
    if not CORE_SHA256 or hashlib.sha256(CORE.read_bytes()).hexdigest() != CORE_SHA256:
        raise BuildGateError("WRT-CORE.yml changed: review and refresh the CNB replay lock")
    steps = yaml.safe_load(CORE.read_text(encoding="utf-8"))["jobs"]["build"]["steps"]
    found = {s.get("name"): s for s in steps}
    if len(found) != len(steps) or any(name not in found for name in STEPS):
        raise BuildGateError("missing or duplicated WRT-CORE build step")
    positions = [steps.index(found[name]) for name in STEPS]
    if positions != sorted(positions) or any("run" not in found[name] for name in STEPS):
        raise BuildGateError("WRT-CORE build order or run body changed")
    for name in STEPS:
        if EXPRESSION.search(found[name]["run"]) and name != "Reserve Disk Space Before Compile":
            raise BuildGateError(f"unexpected GitHub expression in build step {name}")
        if "uses" in found[name]:
            raise BuildGateError(f"unexpected third-party action in build step {name}")
    return found


def profile_inputs(name):
    if name not in PROFILES:
        raise BuildGateError("unsupported device profile")
    profile = PROFILES[name]
    raw = verify_profile(ROOT, profile)
    source = yaml.safe_load(CORE.read_text(encoding="utf-8"))
    # PyYAML 1.1 treats the YAML `on` keyword as boolean True.
    declared = source.get("on", source.get(True))["workflow_call"]["inputs"]
    result = {}
    for key, spec in declared.items():
        value = raw.get(key, spec.get("default", ""))
        if key == "WRT_IP":
            if value != profile["lan"] and not str(value).startswith("${{ inputs."):
                raise BuildGateError("caller LAN default changed; review CNB profile")
            value = profile["lan"]
        elif key == "WRT_WAN_PROTOCOL" and value == "${{ inputs.WAN_PROTOCOL || 'dhcp' }}":
            value = "dhcp"
        elif key == "DEBUG_SSH" and value == "${{ inputs.DEBUG_SSH }}":
            value = "false"  # Never hold or enroll a CNB builder.
        if value is None:
            value = ""
        value = str(value).lower() if isinstance(value, bool) else str(value)
        if key == "RUNNER_LABELS" and value.startswith("'") and value.endswith("'"):
            value = value[1:-1]  # job_inputs reads literal YAML text, not parsed scalars.
        if "${{" in value:
            raise BuildGateError(f"unresolved caller expression for {key}")
        result[key] = value
    if (result["WRT_BUILD_ONLY"], result["WRT_FEATURE_OVERLAY"],
            result["WRT_COMMIT"], result["WRT_WAN_PROTOCOL"]) != (
            "true", "true", "a4638cd4389183f1a1fcad0441f491ca11c97757", "dhcp"):
        raise BuildGateError("unsafe or drifted private build inputs")
    if result["WRT_TEST"] or result["DEBUG_SSH"] != "false":
        raise BuildGateError("test/debug mode cannot run the private build pilot")
    if result["WRT_CONTAINER_RUNTIME_TEST"] != "true" or result["WRT_CONTAINER_RUNTIME_MODE"] != "prebuilt":
        raise BuildGateError("container runtime inputs drifted from the RE GitHub default")
    return result


def clean_optional(value):
    """Treat documented optional placeholders as absent, never embed them."""
    value = value or ""
    stripped = value.strip().strip("\"'")
    if stripped.startswith("<") and stripped.endswith(">"):
        return ""
    if "${{" in stripped:
        return ""
    return value


def secret_env(base):
    if not base.get("SAMBA_DEFAULT_PASSWORD") or clean_optional(base["SAMBA_DEFAULT_PASSWORD"]) == "":
        raise BuildGateError("Samba build credential is missing or a placeholder")
    return {k: clean_optional(base.get(k, "")) for k in SENSITIVE}


def step_env(stage, env, secrets):
    result = env.copy()
    for key, value in stage.get("env", {}).items():
        if not isinstance(value, str):
            result[key] = str(value).lower() if isinstance(value, bool) else str(value)
            continue
        def lookup(match):
            expr = match.group(1)
            if expr.startswith("secrets.") and expr[8:] in SENSITIVE:
                return secrets[expr[8:]]
            if expr.startswith("env.") and expr[4:] in result:
                return result[expr[4:]]
            if expr in ("steps.cache_restore.outputs.cache-hit",
                        "steps.cache_restore.outputs.cache-primary-key",
                        "steps.cache_save.outcome"):
                return ""
            raise BuildGateError(f"unhandled step env expression in {stage['name']}")
        result[key] = EXPRESSION.sub(lookup, value)
        if "${{" in result[key]:
            raise BuildGateError(f"unresolved expression in {stage['name']}")
    return result


def apply_outputs(path, env):
    if not path.exists():
        raise BuildGateError("missing GitHub environment handoff file")
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if not sep or not ALLOWED_OUTPUT.fullmatch(key) or "\x00" in value:
            raise BuildGateError("unexpected key or malformed GitHub environment output")
        env[key] = value
    path.write_text("", encoding="utf-8")


def check_metadata(env):
    upload = ROOT / "wrt/upload"
    metadata = upload / "metadata.json"
    if not metadata.is_file() or not (upload / "SHA256SUMS").is_file():
        raise BuildGateError("firmware metadata or SHA256SUMS missing")
    data = json.loads(metadata.read_text(encoding="utf-8"))
    expected = {"workflow_commit": env["GITHUB_SHA"], "source_commit": env["WRT_HASH"],
                "config": env["WRT_CONFIG"], "required_device": env["WRT_REQUIRED_DEVICE"]}
    if any(data.get(k) != v for k, v in expected.items()):
        raise BuildGateError("firmware metadata does not match checked-out inputs")
    if data.get("source_commit") != env["WRT_COMMIT"] or data.get("source_repository") != env["WRT_REPO"]:
        raise BuildGateError("firmware metadata source identity drifted")
    if env.get("WRT_PRIVATE_BUILD") != "true" or env.get("WRT_ARTIFACT_PRIVACY_SUFFIX") != "private":
        raise BuildGateError("firmware was not classified as private")
    files = sorted(p.name for p in upload.iterdir() if p.is_file() and p.name != "SHA256SUMS")
    sums = (upload / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    if sorted(x[66:] for x in sums if re.fullmatch(r"[0-9a-f]{64}  [^/\\]+", x)) != files or len(sums) != len(files):
        raise BuildGateError("SHA256SUMS does not cover the exact top-level artifact set")
    subprocess.run(["bash", str(ROOT / "Scripts/GuardReCs07Artifact.sh"), "verify",
                    str(upload), env["WRT_EXPECTED_DEVICE"]], check=True, cwd=ROOT, env=env)


def pin_github_cpu_count():
    """Match GitHub's four build CPUs unless the devbox asks for all of them.

    CNB allocates memory as cpus * 2 GiB; requesting only four CPUs
    would halve available memory. Affinity propagates to make and its
    children, so the unchanged GitHub `make -j$(nproc)` uses four jobs.

    A devbox long-compile run sets CNB_REPLAY_CPU_PIN=native to keep every
    allocated CPU: the firmware bytes do not depend on the job count, only
    the wall clock does, and the build pipeline's 120 minute cap is the
    reason the devbox route exists.
    """
    requested = os.environ.get("CNB_REPLAY_CPU_PIN", "4").strip().lower()
    available = sorted(os.sched_getaffinity(0))
    if len(available) < 4:
        raise BuildGateError("CNB builder has fewer than four available CPUs")
    if requested in ("native", "all"):
        print(f"CNB build CPU affinity: native ({len(available)} CPUs)", flush=True)
        return
    if not requested.isdigit() or not 1 <= int(requested) <= len(available):
        raise BuildGateError(
            "CNB_REPLAY_CPU_PIN must be a CPU count within the allocation or 'native'")
    pinned = int(requested)
    os.sched_setaffinity(0, available[:pinned])
    if len(os.sched_getaffinity(0)) != pinned:
        raise BuildGateError("CNB builder CPU affinity is not the requested count")
    print(f"CNB build CPU affinity: {pinned} CPUs", flush=True)


def run(name):
    pin_github_cpu_count()
    steps = workflow_steps()
    inputs = profile_inputs(name)
    secrets = secret_env(os.environ)
    if (ROOT / "wrt").exists() or not (ROOT / ".git").exists():
        raise BuildGateError("must start from a fresh checked-out repository without wrt/")
    git_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", git_sha):
        raise BuildGateError("invalid CNB workflow checkout identity")
    host = os.environ.copy()
    for key in ("CNB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"):
        host.pop(key, None)
    host.update({k: v for k, v in inputs.items()})
    host.update({"GITHUB_WORKSPACE": str(ROOT), "GITHUB_SHA": git_sha,
                 "GITHUB_REPOSITORY": "hotwa/OpenWRT-CI", "GITHUB_RUN_ID": str(int(time.time())),
                 "GITHUB_RUN_ATTEMPT": "1", "WRT_CI": "", "WRT_PRIVATE_BUILD": "false",
                 "WRT_PRIVATE_BUILD_REASON": "", "WRT_ARTIFACT_PRIVACY_SUFFIX": "public",
                 "WRT_CACHE_LOW_WATER_GB": "12", "WRT_CACHE_TARGET_FREE_GB": "20",
                 "WRT_CCACHE_MAX_SIZE": "5G", "WRT_GO_BUILD_MAX": "2G", "WRT_GOMOD_MAX": "3G",
                 "PATH": HOST_PATH + ":" + host["PATH"], "TZ": "Asia/Shanghai"})
    for key in SENSITIVE:
        host[key] = secrets[key]
    for command, expected in (("go", "go version go1.26.0 linux/amd64"), ("node", "v24.20.0")):
        args = [command, "version"] if command == "go" else [command, "--version"]
        if subprocess.check_output(args, env=host, text=True).strip() != expected:
            raise BuildGateError(f"host {command} version differs from GitHub build pin")
    with tempfile.TemporaryDirectory(prefix="cnb-re-build-") as tmp:
        host["RUNNER_TEMP"] = tmp
        environment_file = Path(tmp) / "github-env"
        host["GITHUB_ENV"] = str(environment_file)
        environment_file.touch(mode=0o600)
        for step_name in STEPS:
            stage = steps[step_name]
            script = stage["run"]
            if step_name == "Reserve Disk Space Before Compile":
                literal = "${{ inputs.RUNNER_LABELS }}"
                if script.count(literal) != 1:
                    raise BuildGateError("GHA runner-label expression drifted")
                script = script.replace(literal, inputs["RUNNER_LABELS"])
            if "${{" in script:
                raise BuildGateError(f"unresolved shell expression in {step_name}")
            environment_file.write_text("", encoding="utf-8")
            stage_file = Path(tmp) / "stage.sh"
            stage_file.write_text(script, encoding="utf-8")
            print(f"CNB replay GHA build stage: {step_name}", flush=True)
            subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail",
                            str(stage_file)], cwd=ROOT, env=step_env(stage, host, secrets), check=True)
            apply_outputs(environment_file, host)
            if step_name == "Clone Code":
                actual = subprocess.check_output(["git", "-C", str(ROOT / "wrt"), "rev-parse", "HEAD"],
                                                 text=True, env=host).strip()
                if actual != host["WRT_COMMIT"]:
                    raise BuildGateError("checked-out OpenWrt source does not match pinned SHA")
            if step_name == "Update Feeds":
                for relative in ("tmp/.packageinfo", "tmp/.targetinfo"):
                    if not (ROOT / "wrt" / relative).is_file() or (ROOT / "wrt" / relative).stat().st_size == 0:
                        raise BuildGateError(f"feeds returned success without {relative}")
            if step_name in ("Custom Packages and Agent Runtimes",
                             "Inject Private Firmware Configuration") and (
                    host.get("WRT_PRIVATE_BUILD") != "true" or
                    host.get("WRT_ARTIFACT_PRIVACY_SUFFIX") != "private"):
                raise BuildGateError("private firmware guard was not upheld")
        check_metadata(host)
    print("CNB device-free private firmware build and local artifact guards passed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=sorted(PROFILES))
    args = parser.parse_args()
    try:
        run(args.profile)
    except (BuildGateError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        # Never print subprocess env, imported values or secret-bearing command text.
        if isinstance(exc, subprocess.CalledProcessError):
            print("ERROR: CNB build stage failed; inspect preceding stage log", file=sys.stderr)
        else:
            print(f"ERROR: CNB build gate: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
