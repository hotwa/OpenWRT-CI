#!/usr/bin/env python3
"""Fail closed if the initial CNB pipeline gains credentials or deployment."""
from pathlib import Path
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent


class ShadowPipelineTest(unittest.TestCase):
    def test_branch_scoped_profiles_and_weekly_upstream_report(self):
        config = yaml.safe_load((ROOT / ".cnb.yml").read_text(encoding="utf-8"))
        self.assertEqual(list(config), ["migration/cnb-shadow-20260926"])
        branch = config["migration/cnb-shadow-20260926"]
        self.assertEqual(list(branch), [
            "push", "web_trigger_re_preflight", "crontab: 0 9 * * 0"
        ])
        self.assertEqual(len(branch["push"]), 2)
        pipeline = branch["push"][0]
        self.assertEqual(set(pipeline), {"name", "docker", "stages"})
        self.assertEqual(pipeline["docker"], {"image": "ubuntu:24.04"})
        self.assertEqual(len(pipeline["stages"]), 1)
        self.assertEqual(
            pipeline["stages"][0]["script"], "bash Scripts/cnb_shadow_probe.sh"
        )
        self.assertEqual(set(pipeline["stages"][0]), {"name", "script"})
        profiles = branch["push"][1]
        self.assertEqual(set(profiles), {"name", "docker", "stages"})
        self.assertEqual(profiles["docker"], {"image": "python:3.13-bookworm"})
        self.assertEqual(len(profiles["stages"]), 1)
        self.assertEqual(profiles["stages"][0]["script"],
                         "unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN; python3 Scripts/cnb_re_profile_preflight.py")
        scheduled = branch
        self.assertEqual(set(scheduled) - {"push"}, {
            "web_trigger_re_preflight", "crontab: 0 9 * * 0"
        })
        manual = scheduled["web_trigger_re_preflight"][0]
        self.assertEqual(manual["stages"][0]["script"],
                         "unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN; python3 Scripts/cnb_re_profile_preflight.py")
        self.assertEqual(len(scheduled["crontab: 0 9 * * 0"]), 1)
        weekly = scheduled["crontab: 0 9 * * 0"][0]
        self.assertEqual(weekly["docker"], profiles["docker"])
        self.assertEqual(weekly["stages"], [
            {"name": "Compare pinned sources to upstream history (no pin changes)",
             "script": "unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN; python3 Scripts/cnb_upstream_report.py",
             "timeout": "8m"}
        ])
        self.assertEqual(set(weekly), {"name", "docker", "stages"})

    def test_no_secret_release_or_device_actions(self):
        text = (ROOT / ".cnb.yml").read_text(encoding="utf-8")
        probe = (ROOT / "Scripts/cnb_shadow_probe.sh").read_text(encoding="utf-8")
        for pattern in (
            r"\bimports\s*:", r"\binclude\s*:", r"\benv\s*:",
            r"\bpull_request\s*:",
            r"\b(schedule|tag_push|api_trigger)\s*:",
            r"\b(cnb:apply|cnb:trigger|docker:cache)\b",
        ):
            self.assertNotRegex(text, pattern)
        self.assertIn("unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN", probe)
        for command in ("ssh ", "scp ", "sysupgrade ", "curl ", "wget "):
            self.assertNotIn(command, probe)
        self.assertRegex(probe, re.compile(r"bash \"\$test_script\""))
        buttons = yaml.safe_load((ROOT / ".cnb/web_trigger.yml").read_text(encoding="utf-8"))
        self.assertEqual(len(buttons["branch"]), 1)
        self.assertEqual(buttons["branch"][0]["reg"], "^migration/cnb-shadow-20260926$")
        self.assertEqual({b["event"] for b in buttons["branch"][0]["buttons"]},
                         {"web_trigger_re_preflight"})
        for button in buttons["branch"][0]["buttons"]:
            self.assertNotIn("permissions", button)  # CNB still requires repository write permission
            self.assertNotIn("inputs", button)
            self.assertNotIn("env", button)


if __name__ == "__main__":
    unittest.main()
