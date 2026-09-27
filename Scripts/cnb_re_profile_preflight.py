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
# QCA-6.18 callers do not pin the source at all (they float on main). A CNB
# fallback must be reproducible, so those profiles declare their own pin here;
# the value is the same reviewed ImmortalWrt commit the other profiles use.
QCA_PIN = PIN

# Default expectations of the audited private pilot. A profile may override any
# of them, and every expectation is still checked exactly (fail closed) against
# the GitHub caller, so a drifted caller can never change a CNB build silently.
PILOT_EXPECTATIONS = {
    "commit": PIN,
    "pin_in_caller": True,
    "build_only": True,
    "feature_overlay": True,
    "emmc": True,
    "container_runtime_test": True,
    "container_runtime_mode": "prebuilt",
    "expected_device": True,
    "expect_required_device": True,
    "allow_test": False,
    "required_secrets": ("SAMBA_DEFAULT_PASSWORD",),
}


def profile_expectations(profile):
    """Merge a profile's explicit expectations over the audited pilot defaults."""
    expected = dict(PILOT_EXPECTATIONS)
    expected.update({k: v for k, v in profile.items() if k in PILOT_EXPECTATIONS})
    return expected


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
    # CPE-5G: the 706 board with its own reviewed pin, no WRT_EXPECTED_DEVICE and
    # no build-only flag. Its callers inject the device activation key, so a real
    # CNB firmware build must fail closed while that key is absent.
    # Disabled in the one-click fleet by user decision: the profile identity stays
    # verified so re-enabling is a single pipeline block, but no pipeline may use
    # it (a test asserts that).
    "cpe5g-a": {
        "disabled_in_fleet": True,
        "workflow": "CPE-5G.yml", "job": "baseline_a",
        "config": "IPQ60XX-706-NOWIFI", "device": "jdcloud_re-ss-01",
        "name": "CPE-706-A", "lan": "192.168.10.1",
        "commit": "0bad892975fe49fd180f99b414a7f168bb694dd7",
        "build_only": False, "feature_overlay": False, "emmc": False,
        "container_runtime_test": False, "expected_device": False,
        "expect_required_device": True, "required_device": "jdcloud_re-ss-01",
        "allow_test": True,
        "required_secrets": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
    },
    "cpe5g-b": {
        "workflow": "CPE-5G.yml", "job": "cpe_overlay_b",
        "config": "IPQ60XX-706-NOWIFI", "device": "jdcloud_re-ss-01",
        "name": "CPE-5G", "lan": "192.168.13.1",
        "commit": "0bad892975fe49fd180f99b414a7f168bb694dd7",
        "build_only": False, "feature_overlay": True, "emmc": False,
        "container_runtime_test": False, "expected_device": False,
        "expect_required_device": True, "required_device": "jdcloud_re-ss-01",
        "allow_test": True,
        "required_secrets": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
    },
    # Config-only render of the same caller: WRT_TEST mode, no firmware, so it is
    # deliberately not gated on the device activation key.
    "cpe5g-b-configonly": {
        "workflow": "CPE-5G.yml", "job": "cpe_overlay_b",
        "config": "IPQ60XX-706-NOWIFI", "device": "jdcloud_re-ss-01",
        "name": "CPE-5G", "lan": "192.168.13.1",
        "commit": "0bad892975fe49fd180f99b414a7f168bb694dd7",
        "build_only": False, "feature_overlay": True, "emmc": False,
        "container_runtime_test": False, "expected_device": False,
        "expect_required_device": True, "required_device": "jdcloud_re-ss-01",
        "allow_test": True,
        "required_secrets": ("SAMBA_DEFAULT_PASSWORD",),
    },
    # QCA-6.18 matrix, statically expanded. The GitHub caller pins nothing, so
    # the profile declares the reviewed ImmortalWrt commit and the replay records
    # it as source_commit; the caller's ${{matrix.*}} values are resolved here.
    "qca-ipq60xx-wifi-no": {
        "workflow": "QCA-6.18-VIKINGYFY.yml", "job": "config",
        "config": "IPQ60XX-WIFI-NO", "device": None,
        "name": "DAE-WRT", "lan": "192.168.10.1",
        "commit": QCA_PIN, "pin_in_caller": False, "matrix_expansion": True,
        "build_only": False, "emmc": False, "container_runtime_test": False,
        "expected_device": False, "expect_required_device": False, "allow_test": True,
        "required_secrets": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
    },
    "qca-ipq60xx-wifi-yes": {
        "workflow": "QCA-6.18-VIKINGYFY.yml", "job": "config",
        "config": "IPQ60XX-WIFI-YES", "device": None,
        "name": "DAE-WRT", "lan": "192.168.10.1",
        "commit": QCA_PIN, "pin_in_caller": False, "matrix_expansion": True,
        "build_only": False, "emmc": False, "container_runtime_test": False,
        "expected_device": False, "expect_required_device": False, "allow_test": True,
        "required_secrets": ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"),
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
    lines = with_block.splitlines()
    index = 0
    while index < len(lines):
        match = re.match(r"^      ([A-Z][A-Z0-9_]*):\s*([^\n#]*)", lines[index])
        if not match:
            index += 1
            continue
        key, raw_value = match.group(1), match.group(2).strip()
        if key in result:
            raise ValueError(f"duplicate {key} in {job}")
        if raw_value in ("|", ">"):
            # Block scalar (for example the CPE-5G package list): keep every
            # more-indented line verbatim instead of the literal indicator.
            block = []
            index += 1
            while index < len(lines) and (not lines[index].strip()
                                          or lines[index].startswith("        ")):
                block.append(lines[index][8:] if lines[index].startswith("        ")
                             else "")
                index += 1
            result[key] = "\n".join(block).strip("\n")
            continue
        if len(raw_value) >= 2 and raw_value[0] == raw_value[-1] and raw_value[0] in "'\"":
            raw_value = raw_value[1:-1]
        result[key] = raw_value
        index += 1
    return result


def verify_profile(root, profile):
    caller = root / ".github/workflows" / profile["workflow"]
    values = job_inputs(caller, profile["job"])
    exp = profile_expectations(profile)
    if profile.get("matrix_expansion"):
        # Static expansion of the GitHub matrix for this profile.
        matrix = {
            "${{matrix.CONFIG}}": profile["config"],
            "${{matrix.SOURCE}}": "VIKINGYFY/immortalwrt",
            "${{matrix.BRANCH}}": "main",
        }
        def expand(value):
            for token, replacement in matrix.items():
                value = value.replace(token, replacement)
            return value
        values = {k: expand(v) for k, v in values.items()}
    elif any("${{matrix." in v for v in values.values()):
        raise ValueError(f"{caller.name}/{profile['job']}: unreviewed matrix expression")
    expected = {
        "WRT_CONFIG": profile["config"],
        "WRT_NAME": profile["name"],
        "WRT_REPO": SOURCE,
        "WRT_BRANCH": "main",
    }
    if exp["pin_in_caller"]:
        expected["WRT_COMMIT"] = exp["commit"]
    elif values.get("WRT_COMMIT"):
        raise ValueError(f"{caller.name}/{profile['job']}: caller gained a pin; review the CNB profile")
    if exp["build_only"]:
        expected["WRT_BUILD_ONLY"] = "true"
    if exp["feature_overlay"]:
        expected["WRT_FEATURE_OVERLAY"] = "true"
    if exp["emmc"]:
        expected["WRT_EMMC_DATA_PROVISIONING"] = "true"
    if exp["container_runtime_test"]:
        expected["WRT_CONTAINER_RUNTIME_TEST"] = "true"
    if exp["expected_device"]:
        expected["WRT_EXPECTED_DEVICE"] = profile["device"]
    if exp["expect_required_device"]:
        expected["WRT_REQUIRED_DEVICE"] = profile.get("required_device") or profile["device"]
    for key, value in expected.items():
        if values.get(key) != value:
            raise ValueError(f"{caller.name}/{profile['job']}: {key} drifted from CNB profile")
    if profile.get("device"):
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
