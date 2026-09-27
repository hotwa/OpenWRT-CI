#!/usr/bin/env python3
"""Offline contract checks for CNB replay of the pinned GitHub build scripts."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
import cnb_replay_core as core  # noqa: E402


class CnbReplayCoreTest(unittest.TestCase):
    def test_build_affinity_matches_four_cpu_github_runner(self):
        with patch.object(core.os, "sched_getaffinity", side_effect=[{3, 5, 7, 9, 11}, {3, 5, 7, 9}], create=True), \
                patch.object(core.os, "sched_setaffinity", create=True) as set_affinity:
            core.pin_github_cpu_count()
            set_affinity.assert_called_once_with(0, [3, 5, 7, 9])
        with patch.object(core.os, "sched_getaffinity", return_value={3, 5, 7}, create=True):
            with self.assertRaises(core.BuildGateError):
                core.pin_github_cpu_count()

    def test_devbox_can_keep_every_allocated_cpu(self):
        with patch.dict(core.os.environ, {"CNB_REPLAY_CPU_PIN": "native"}), \
                patch.object(core.os, "sched_getaffinity", return_value={3, 5, 7, 9, 11}, create=True), \
                patch.object(core.os, "sched_setaffinity", create=True) as set_affinity:
            core.pin_github_cpu_count()
            set_affinity.assert_not_called()
        with patch.dict(core.os.environ, {"CNB_REPLAY_CPU_PIN": "99"}), \
                patch.object(core.os, "sched_getaffinity", return_value={3, 5, 7, 9}, create=True):
            with self.assertRaises(core.BuildGateError):
                core.pin_github_cpu_count()

    def test_only_reviewed_original_run_steps(self):
        found = core.workflow_steps()
        self.assertEqual(len(core.STEPS), len(set(core.STEPS)))
        self.assertEqual(found["Custom Packages and Agent Runtimes"]["id"], "custom_packages")
        self.assertIn("Scripts/PrivateFirmwareGuard.sh", found["Inject Private Firmware Configuration"]["run"])
        self.assertIn("GuardReCs07Artifact.sh", found["Package Firmware"]["run"])
        for forbidden in ("CI Debug Gate (Tailscale SSH)", "Define Public Release Input",
                          "Split Public Firmware Artifacts By Device"):
            self.assertNotIn(forbidden, core.STEPS)
        with patch.object(core, "CORE_SHA256", "0" * 64):
            with self.assertRaises(core.BuildGateError):
                core.workflow_steps()

    def test_three_profiles_preserve_pins_and_private_build_only(self):
        for profile, lan in (("re-cs-07", "192.168.10.1"),
                             ("re-cs-02", "192.168.11.1"),
                             ("re-ss-01", "192.168.12.1")):
            with self.subTest(profile=profile):
                data = core.profile_inputs(profile)
                self.assertEqual(data["WRT_IP"], lan)
                self.assertEqual(data["WRT_BUILD_ONLY"], "true")
                self.assertEqual(data["WRT_FEATURE_OVERLAY"], "true")
                self.assertEqual(data["WRT_WAN_PROTOCOL"], "dhcp")
                self.assertEqual(data["DEBUG_SSH"], "false")
                self.assertEqual(data["WRT_COMMIT"],
                                 "a4638cd4389183f1a1fcad0441f491ca11c97757")

    def test_missing_samba_rejected_optional_placeholders_are_omitted(self):
        with self.assertRaises(core.BuildGateError):
            core.secret_env({})
        with self.assertRaises(core.BuildGateError):
            core.secret_env({"SAMBA_DEFAULT_PASSWORD": "<fill>"})
        values = core.secret_env({"SAMBA_DEFAULT_PASSWORD": "synthetic-only",
                                  "HEADSCALE_OPENWRT_AUTHKEY": "",
                                  "MULTICA_TOKEN": "<optional-placeholder>"})
        self.assertEqual(values["SAMBA_DEFAULT_PASSWORD"], "synthetic-only")
        self.assertEqual(values["HEADSCALE_OPENWRT_AUTHKEY"], "")
        self.assertEqual(values["MULTICA_TOKEN"], "")
        stage = {"name": "test", "env": {"a": "${{ secrets.SAMBA_DEFAULT_PASSWORD }}",
                                          "b": "${{ env.WRT_CONFIG }}"}}
        self.assertEqual(core.step_env(stage, {"WRT_CONFIG": "x"}, values)["a"], "synthetic-only")
        with self.assertRaises(core.BuildGateError):
            core.step_env({"name": "test", "env": {"X": "${{ github.token }}"}}, {}, values)

    def test_environment_handoff_is_strict(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "env"
            path.write_text("WRT_PRIVATE_BUILD=true\nWRT_ARTIFACT_PRIVACY_SUFFIX=private\n", encoding="utf-8")
            values = {}
            core.apply_outputs(path, values)
            self.assertEqual(values["WRT_PRIVATE_BUILD"], "true")
            self.assertEqual(path.read_text(), "")
            path.write_text("SECRET_LEAK=dummy\n", encoding="utf-8")
            with self.assertRaises(core.BuildGateError):
                core.apply_outputs(path, values)

    def test_artifact_metadata_checksum_and_private_classification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upload = root / "wrt/upload"
            upload.mkdir(parents=True)
            env = {"GITHUB_SHA": "a" * 40, "WRT_HASH": "b" * 40,
                   "WRT_COMMIT": "b" * 40, "WRT_CONFIG": "IPQ60XX-RE-CS-07-NOWIFI",
                   "WRT_REPO": "https://github.com/VIKINGYFY/immortalwrt.git",
                   "WRT_REQUIRED_DEVICE": "jdcloud_re-cs-07",
                   "WRT_EXPECTED_DEVICE": "jdcloud_re-cs-07",
                   "WRT_PRIVATE_BUILD": "true", "WRT_ARTIFACT_PRIVACY_SUFFIX": "private"}
            metadata = {"workflow_commit": env["GITHUB_SHA"],
                        "source_commit": env["WRT_HASH"], "config": env["WRT_CONFIG"],
                        "source_repository": env["WRT_REPO"],
                        "required_device": env["WRT_REQUIRED_DEVICE"]}
            (upload / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            (upload / "image-sysupgrade.bin").write_bytes(b"synthetic-image")
            lines = [hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name
                     for p in sorted(upload.iterdir())]
            (upload / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
            with patch.object(core, "ROOT", root), patch.object(core.subprocess, "run") as run:
                core.check_metadata(env)
                run.assert_called_once()
                (upload / "extra.txt").write_text("x", encoding="utf-8")
                with self.assertRaises(core.BuildGateError):
                    core.check_metadata(env)
                (upload / "extra.txt").unlink()
                env["WRT_PRIVATE_BUILD"] = "false"
                with self.assertRaises(core.BuildGateError):
                    core.check_metadata(env)


if __name__ == "__main__":
    unittest.main()
