#!/usr/bin/env python3
"""Fail closed if the initial CNB pipeline gains credentials or deployment."""
from pathlib import Path
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent


class ShadowPipelineTest(unittest.TestCase):
    def test_trusted_branch_only_and_single_probe(self):
        config = yaml.safe_load((ROOT / ".cnb.yml").read_text(encoding="utf-8"))
        self.assertEqual(list(config), ["migration/cnb-shadow-*"])
        branch = config["migration/cnb-shadow-*"]
        self.assertEqual(list(branch), ["push"])
        self.assertEqual(len(branch["push"]), 1)
        pipeline = branch["push"][0]
        self.assertEqual(set(pipeline), {"name", "docker", "stages"})
        self.assertEqual(pipeline["docker"], {"image": "ubuntu:24.04"})
        self.assertEqual(len(pipeline["stages"]), 1)
        self.assertEqual(
            pipeline["stages"][0]["script"], "bash Scripts/cnb_shadow_probe.sh"
        )
        self.assertEqual(set(pipeline["stages"][0]), {"name", "script"})

    def test_no_secret_release_or_device_actions(self):
        text = (ROOT / ".cnb.yml").read_text(encoding="utf-8")
        probe = (ROOT / "Scripts/cnb_shadow_probe.sh").read_text(encoding="utf-8")
        for pattern in (
            r"\bimports\s*:", r"\binclude\s*:", r"\benv\s*:",
            r"\bpull_request\s*:", r"\bweb_trigger\w*\s*:",
            r"\b(schedule|tag_push|api_trigger)\s*:",
            r"\b(cnb:apply|cnb:trigger|docker:cache)\b",
        ):
            self.assertNotRegex(text, pattern)
        self.assertIn("unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN", probe)
        for command in ("ssh ", "scp ", "sysupgrade ", "curl ", "wget "):
            self.assertNotIn(command, probe)
        self.assertRegex(probe, re.compile(r"bash \"\$test_script\""))


if __name__ == "__main__":
    unittest.main()
