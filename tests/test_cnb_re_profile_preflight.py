"""Offline identity guards for RE-CS-07, RE-CS-02 and RE-SS-01 CNB profiles."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/cnb_re_profile_preflight.py"
spec = importlib.util.spec_from_file_location("cnb_re_profile_preflight", SCRIPT)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class ReProfilePreflightTests(unittest.TestCase):
    def test_current_callers_and_device_config_match(self):
        self.assertEqual(set(preflight.PROFILES), {"re-cs-07", "re-cs-02", "re-ss-01"})
        for profile in preflight.PROFILES.values():
            with self.subTest(profile=profile["name"]):
                preflight.verify_profile(preflight.ROOT, profile)

    def test_pin_board_and_defaults_fail_closed(self):
        original = preflight.PROFILES["re-cs-07"]
        workflow = (preflight.ROOT / ".github/workflows" / original["workflow"]).read_text(encoding="utf-8")
        config = (preflight.ROOT / "Config" / (original["config"] + ".txt")).read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wf_path = root / ".github/workflows" / original["workflow"]
            wf_path.parent.mkdir(parents=True)
            cfg_path = root / "Config" / (original["config"] + ".txt")
            cfg_path.parent.mkdir(parents=True)
            (root / "Config/GENERAL.txt").write_text("shared", encoding="utf-8")
            wf_path.write_text(workflow.replace(preflight.PIN, "main"), encoding="utf-8")
            cfg_path.write_text(config, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "WRT_COMMIT"):
                preflight.verify_profile(root, original)
            wf_path.write_text(workflow, encoding="utf-8")
            cfg_path.write_text(config.replace("DEVICE_jdcloud_re-cs-07=y", "DEVICE_other=y"), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "does not select"):
                preflight.verify_profile(root, original)
            cfg_path.write_text(config, encoding="utf-8")
            preflight.verify_profile(root, original)

    def test_conflicting_job_lookup_does_not_fall_through_to_other_target(self):
        mesh = preflight.ROOT / ".github/workflows/RE-Mesh-BUILD.yml"
        cs02 = preflight.job_inputs(mesh, "re_cs_02")
        ss01 = preflight.job_inputs(mesh, "re_ss_01")
        self.assertEqual(cs02["WRT_EXPECTED_DEVICE"], "jdcloud_re-cs-02")
        self.assertEqual(ss01["WRT_EXPECTED_DEVICE"], "jdcloud_re-ss-01")
        with self.assertRaisesRegex(ValueError, "missing workflow job"):
            preflight.job_inputs(mesh, "re_cs_08")


if __name__ == "__main__":
    unittest.main()
