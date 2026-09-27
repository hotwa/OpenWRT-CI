#!/usr/bin/env python3
"""Guards for the unfilled CNB secret template and the manual audit workflow.

The template must stay free of values, its name list must match the CNB profile
requirements, and the audit workflow must be manual-only and never interpolate a
secret into a command, log or file.
"""

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
import cnb_secret_inventory as inventory  # noqa: E402

TEMPLATE = ROOT / ".cnb/cloud-secret-env.build.template.yml"
AUDIT_WORKFLOW = ROOT / ".github/workflows/CNB-Secret-Audit.yml"
DEPLOYMENT_SECRETS = ("FIRMWARE_CD_SSH_PRIVATE_KEY", "FIRMWARE_CD_KNOWN_HOSTS",
                      "AGENT_RUNTIME_USIGN_SECRET_KEY")


class SecretTemplateTests(unittest.TestCase):
    def test_template_is_placeholders_only_and_complete(self):
        self.assertEqual(inventory.validate_template(TEMPLATE), [])
        data = yaml.safe_load(TEMPLATE.read_text(encoding="utf-8"))
        names = [key for key in data if not key.startswith("allow_")]
        info = inventory.classification()
        required = sorted(name for name in names if data[name] == "<FILL:required>")
        self.assertEqual(required, info["required_union"])
        for name in names:
            self.assertRegex(data[name], r"^<FILL:(required|optional)>$")
        for forbidden in DEPLOYMENT_SECRETS:
            self.assertNotIn(forbidden, names)
        # No value-shaped content may appear anywhere in the template.
        text = TEMPLATE.read_text(encoding="utf-8")
        self.assertNotRegex(text, r"[A-Za-z0-9+/_=-]{40,}")
        self.assertNotIn("set", [data[name] for name in names])

    def test_secret_names_match_profile_requirements(self):
        per_profile, union = inventory.profile_requirements()
        info = inventory.classification()
        self.assertEqual(info["required_union"], union)
        self.assertEqual(sorted(info["required"]), union)
        for name, required in sorted(per_profile.items()):
            with self.subTest(profile=name):
                self.assertIn("SAMBA_DEFAULT_PASSWORD", required)
        self.assertEqual(per_profile["cpe5g-b"],
                         ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"))
        self.assertEqual(per_profile["qca-ipq60xx-wifi-no"],
                         ("SAMBA_DEFAULT_PASSWORD", "HEADSCALE_OPENWRT_AUTHKEY"))
        # A config-only render must not require the device activation key.
        self.assertEqual(per_profile["cpe5g-b-configonly"], ("SAMBA_DEFAULT_PASSWORD",))
        # GitHub-only keys stay out of the CNB build requirement.
        self.assertNotIn("HEADSCALE_CI_AUTHKEY", union)
        self.assertNotIn("HEADSCALE_URL", union)

    def test_audit_workflow_is_manual_only_and_never_reads_values(self):
        self.assertTrue(AUDIT_WORKFLOW.is_file())
        text = AUDIT_WORKFLOW.read_text(encoding="utf-8")
        data = yaml.safe_load(text)
        triggers = data.get("on", data.get(True))
        self.assertEqual(list(triggers), ["workflow_dispatch"])
        self.assertEqual(data["permissions"], {"contents": "read"})
        self.assertNotIn("WRT-CORE.yml", text)
        self.assertNotIn("secrets: inherit", text)
        for reference in re.findall(r"uses:\s*([^\s#]+)", text):
            with self.subTest(action=reference):
                self.assertRegex(reference, r"^[^@]+@[0-9a-f]{40}$")
        # Every secret reference must be a bare presence comparison; anything else
        # could put a value into the environment, a command or the log.
        comparisons = 0
        for line in text.splitlines():
            stripped = line.strip()
            if "secrets." not in line or stripped.startswith("#"):
                continue
            self.assertRegex(
                stripped,
                r"^PRESENT_[A-Z0-9_]+:\s*\$\{\{\s*secrets\.[A-Z0-9_]+ != ''\s*\}\}$")
            comparisons += 1
        info = inventory.classification()
        expected_probes = len(info["required"]) + len(info["optional"]) + len(info["ignored"])
        self.assertEqual(comparisons, expected_probes)
        probed = set(re.findall(r"PRESENT_([A-Z0-9_]+):", text))
        self.assertEqual(probed, set(info["required"] + info["optional"] + info["ignored"]))
        for name in DEPLOYMENT_SECRETS:
            self.assertNotIn(name, probed)
        # The log loop may only print the boolean state.
        self.assertIn("=set", text)
        self.assertIn("=unset", text)
        self.assertNotIn("echo ${{ secrets.", text)
        self.assertNotIn('echo "${!variable}"', text)


if __name__ == "__main__":
    unittest.main()
