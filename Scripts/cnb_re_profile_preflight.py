#!/usr/bin/env python3
"""Verify three RE CNB build profiles against the authoritative GitHub callers.

No credentials are read and no firmware is built. This is a fail-closed input gate.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = "https://github.com/VIKINGYFY/immortalwrt.git"
# Current source pin intentionally copied from the existing GHA callers; changing
# it requires explicit candidate validation, not merely a moving upstream branch.
PIN = "a4638cd4389183f1a1fcad0441f491ca11c97757"
PROFILES = {
    "re-cs-07": {
        "workflow": "RE-CS-07-BUILD.yml", "job": "build",
        "config": "IPQ60XX-RE-CS-07-NOWIFI", "device": "jdcloud_re-cs-07",
        "name": "RE-CS-07", "lan": "192.168.10.1",
    },
    "re-cs-02": {
        "workflow": "RE-Mesh-BUILD.yml", "job": "re_cs_02",
        "config": "IPQ60XX-RE-CS-02", "device": "jdcloud_re-cs-02",
        "name": "RE-CS-02", "lan": "192.168.11.1",
    },
    "re-ss-01": {
        "workflow": "RE-Mesh-BUILD.yml", "job": "re_ss_01",
        "config": "IPQ60XX-RE-SS-01", "device": "jdcloud_re-ss-01",
        "name": "RE-SS-01", "lan": "192.168.12.1",
    },
    # WLG is the RE-CS-07 board with a lab identity (192.168.50.1) and eMMC data
    # provisioning; its caller keeps the same pin, overlay and build-only flags.
    "wlg-re-cs-07": {
        "workflow": "WLG-RE-CS-07-BUILD.yml", "job": "build",
        "config": "IPQ60XX-RE-CS-07-NOWIFI", "device": "jdcloud_re-cs-07",
        "name": "WLG-RE-CS-07", "lan": "192.168.50.1",
    },
}


def job_inputs(workflow, job):
    text = workflow.read_text(encoding="utf-8")
    match = re.search(r"^  " + re.escape(job) + r":\s*$", text, re.M)
    if not match:
        raise ValueError(f"missing workflow job {job}")
    # The next two-space key ends this job. Only literal lines under its with:
    # are considered; no YAML expression is evaluated by this checker.
    block = re.split(r"^  [A-Za-z][A-Za-z0-9_-]*:\s*$", text[match.end():], maxsplit=1, flags=re.M)[0]
    with_pos = re.search(r"^    with:\s*$", block, re.M)
    if not with_pos:
        raise ValueError(f"missing with block in {job}")
    with_block = re.split(r"^    [A-Za-z][A-Za-z0-9_-]*:\s*$", block[with_pos.end():], maxsplit=1, flags=re.M)[0]
    result = {}
    for key, value in re.findall(r"^      ([A-Z][A-Z0-9_]*):\s*([^\n#]+)", with_block, re.M):
        if key in result:
            raise ValueError(f"duplicate {key} in {job}")
        result[key] = value.strip()
    return result


def verify_profile(root, profile):
    caller = root / ".github/workflows" / profile["workflow"]
    values = job_inputs(caller, profile["job"])
    expected = {
        "WRT_CONFIG": profile["config"],
        "WRT_NAME": profile["name"],
        "WRT_REPO": SOURCE,
        "WRT_BRANCH": "main",
        "WRT_COMMIT": PIN,
        "WRT_EXPECTED_DEVICE": profile["device"],
        "WRT_REQUIRED_DEVICE": profile["device"],
        "WRT_BUILD_ONLY": "true",
        "WRT_EMMC_DATA_PROVISIONING": "true",
        "WRT_CONTAINER_RUNTIME_TEST": "true",
        "WRT_FEATURE_OVERLAY": "true",
    }
    for key, value in expected.items():
        if values.get(key) != value:
            raise ValueError(f"{caller.name}/{profile['job']}: {key} drifted from CNB profile")
    config = root / "Config" / (profile["config"] + ".txt")
    if not config.is_file():
        raise ValueError(f"missing device config {config.name}")
    text = config.read_text(encoding="utf-8")
    if not re.search(r"^CONFIG_TARGET_\w+_DEVICE_" + re.escape(profile["device"]) + r"=y$", text, re.M):
        raise ValueError(f"config {config.name} does not select {profile['device']}")
    if not (root / "Config/GENERAL.txt").is_file():
        raise ValueError("missing shared config")
    return values


def main():
    try:
        for name, profile in PROFILES.items():
            verify_profile(ROOT, profile)
            print(f"{name}: pinned-source/device/overlay/build-only identity passed")
        print("RE profile preflight passed; no firmware, secret or device accessed")
    except (OSError, ValueError) as exc:
        print(f"RE profile preflight failed closed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
