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
            "push", "web_trigger_re_host_runtime_probe", "web_trigger_re_attachment_probe",
            "web_trigger_re_private_build", "vscode",
            "web_trigger_re_preflight", "crontab: 0 9 * * 0"
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
            "web_trigger_re_preflight", "web_trigger_re_private_build",
            "web_trigger_re_host_runtime_probe", "web_trigger_re_attachment_probe",
            "vscode",
            "crontab: 0 9 * * 0"
        })
        manual = scheduled["web_trigger_re_preflight"][0]
        self.assertEqual(manual["stages"][0]["script"],
                         "unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN; python3 Scripts/cnb_re_profile_preflight.py")
        runtime = scheduled["web_trigger_re_host_runtime_probe"][0]
        self.assertEqual(set(runtime), {"name", "runner", "docker", "stages"})
        # The pinned official Go/Node archives are x86_64 only and CNB memory is
        # cpus x 2 GiB, so both jobs must state the node and the core count.
        self.assertEqual(runtime["runner"], {"tags": "cnb:arch:amd64", "cpus": 8})
        self.assertEqual(runtime["docker"], {"image": "python:3.13-bookworm"})
        self.assertEqual(runtime["stages"][0]["script"], "bash Scripts/cnb_host_runtime.sh")
        attachment = scheduled["web_trigger_re_attachment_probe"][0]
        self.assertNotIn("imports", attachment)
        self.assertEqual(attachment["stages"][1]["image"],
                         "cnbcool/attachments@sha256:3000e40e6495209ef056c374234f83505525257f799eaf51c9dcf8a8235efdb0")
        self.assertEqual(attachment["stages"][1]["settings"]["attachments"],
                         {"./cnb-attachment-probe.txt": 1})
        # Fan-out contract: one manual event, one pipeline per enabled profile,
        # each on 32 amd64 CPUs with its own private attachment upload. A single
        # click therefore starts all of them concurrently (about 44 core-hours
        # per profile), which is why this event stays manual.
        fleet = scheduled["web_trigger_re_private_build"]
        self.assertEqual(len(fleet), 4)
        for entry, profile in zip(fleet, ("re-cs-07", "re-cs-02", "re-ss-01", "wlg-re-cs-07")):
            with self.subTest(profile=profile):
                self.assertEqual(set(entry), {"name", "imports", "runner", "docker", "stages"})
                self.assertEqual(entry["runner"], {"tags": "cnb:arch:amd64", "cpus": 32})
                self.assertEqual(entry["imports"], [
                    "https://cnb.cool/b2233/cloud-secret/-/blob/main/projects/openwrt-ci/env.build.yml"
                ])
                self.assertEqual(len(entry["stages"]), 7)
                self.assertEqual(entry["stages"][0]["script"],
                                 "bash Scripts/cnb_re_private_input_gate.sh")
                self.assertEqual(entry["stages"][1]["script"],
                                 "bash Scripts/cnb_bootstrap_environment.sh")
                self.assertEqual(entry["stages"][2]["script"],
                                 "bash Scripts/cnb_host_runtime.sh")
                self.assertEqual(entry["stages"][4]["script"],
                                 "bash Scripts/cnb_re_builder_user.sh")
                self.assertEqual(entry["stages"][5]["script"],
                                 "runuser --preserve-environment -u cnbbuild -- env HOME=/home/cnbbuild "
                                 f"CNB_REPLAY_CPU_PIN=native python3 -u Scripts/cnb_replay_core.py {profile}")
                self.assertEqual(entry["stages"][5]["timeout"], "11h")
                self.assertEqual(entry["stages"][6]["image"], attachment["stages"][1]["image"])
                self.assertEqual(entry["stages"][6]["settings"],
                                 {"attachments": ["./wrt/upload/*"], "ttl": 14})
        self.assertEqual([e["name"].split()[2] for e in fleet],
                         ["RE-CS-07", "RE-CS-02", "RE-SS-01", "WLG-RE-CS-07"])
        self.assertEqual(len(scheduled["crontab: 0 9 * * 0"]), 1)
        weekly = scheduled["crontab: 0 9 * * 0"][0]
        self.assertEqual(weekly["docker"], profiles["docker"])
        self.assertEqual(weekly["stages"], [
            {"name": "Compare pinned sources to upstream history (no pin changes)",
             "script": "unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN; python3 Scripts/cnb_upstream_report.py",
             "timeout": "8m"}
        ])
        self.assertEqual(set(weekly), {"name", "docker", "stages"})

    def test_devbox_long_compile_is_branch_scoped_and_bounded(self):
        config = yaml.safe_load((ROOT / ".cnb.yml").read_text(encoding="utf-8"))
        # The devbox must stay a branch-scoped event, never a global "$" entry.
        self.assertNotIn("$", config)
        devbox = config["migration/cnb-shadow-20260926"]["vscode"][0]
        self.assertEqual(set(devbox), {"name", "imports", "runner", "services", "docker", "stages"})
        self.assertEqual(devbox["imports"], [
            "https://cnb.cool/b2233/cloud-secret/-/blob/main/projects/openwrt-ci/env.build.yml"
        ])
        self.assertEqual(devbox["runner"], {"tags": "cnb:arch:amd64", "cpus": 32})
        self.assertEqual(devbox["services"], ["vscode", "docker"])
        self.assertEqual(len(devbox["stages"]), 2)
        self.assertEqual(devbox["stages"][1]["script"], "bash Scripts/cnb_devbox_run.sh")
        script = (ROOT / "Scripts/cnb_devbox_run.sh").read_text(encoding="utf-8")
        # Long compile must survive a stage timeout, keep every CPU, and never
        # print the imported Samba credential.
        self.assertIn("setsid", script)
        self.assertIn("CNB_REPLAY_CPU_PIN=native", script)
        self.assertIn('set +x', script)
        self.assertIn('SAMBA_DEFAULT_PASSWORD', script)
        self.assertNotIn('echo "$SAMBA_DEFAULT_PASSWORD"', script)

    def test_no_secret_release_or_device_actions(self):
        text = (ROOT / ".cnb.yml").read_text(encoding="utf-8")
        probe = (ROOT / "Scripts/cnb_shadow_probe.sh").read_text(encoding="utf-8")
        for pattern in (
            r"\binclude\s*:", r"\benv\s*:",
            r"\bpull_request\s*:",
            r"\b(schedule|tag_push|api_trigger)\s*:",
            r"\b(cnb:apply|cnb:trigger|docker:cache)\b",
        ):
            self.assertNotRegex(text, pattern)
        self.assertIn("unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN", probe)
        branch = yaml.safe_load(text)["migration/cnb-shadow-20260926"]
        for event in ("push", "web_trigger_re_preflight", "web_trigger_re_host_runtime_probe",
                      "web_trigger_re_attachment_probe",
                      "crontab: 0 9 * * 0"):
            self.assertNotIn("imports", str(branch[event]))
        gate = (ROOT / "Scripts/cnb_re_private_input_gate.sh").read_text(encoding="utf-8")
        self.assertIn('set +x', gate)
        self.assertIn('"${SAMBA_DEFAULT_PASSWORD:-}"', gate)
        self.assertNotIn('echo "$SAMBA_DEFAULT_PASSWORD"', gate)
        for command in ("ssh ", "scp ", "sysupgrade ", "curl ", "wget "):
            self.assertNotIn(command, probe)
        self.assertRegex(probe, re.compile(r"bash \"\$test_script\""))
        buttons = yaml.safe_load((ROOT / ".cnb/web_trigger.yml").read_text(encoding="utf-8"))
        self.assertEqual(len(buttons["branch"]), 1)
        self.assertEqual(buttons["branch"][0]["reg"], "^migration/cnb-shadow-20260926$")
        self.assertEqual({b["event"] for b in buttons["branch"][0]["buttons"]},
                         {"web_trigger_re_preflight", "web_trigger_re_host_runtime_probe",
                          "web_trigger_re_attachment_probe", "web_trigger_re_private_build"})
        for button in buttons["branch"][0]["buttons"]:
            self.assertNotIn("permissions", button)  # CNB still requires repository write permission
            self.assertNotIn("inputs", button)
            self.assertNotIn("env", button)


if __name__ == "__main__":
    unittest.main()
