import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest

from Scripts.patch_nikki_router_selector_guard import MARKER, NEW_BLOCK, OLD_BLOCK, WILDCARD, patch


FIXTURE = Path(__file__).parent / "fixtures/nikki/hijack-pinned.ut"
SOURCE = FIXTURE.read_text(encoding="utf-8")
IMPORTS = """\timport { cursor } from 'uci';
\timport { connect } from 'ubus';
\timport { uci_bool, uci_array, get_cgroups_version, get_users, get_groups, get_cgroups, load_profile } from '/etc/nikki/ucode/include.uc';"""
MOCKS = """
function uci_bool(value) { return value == null ? null : value == '1'; }
function uci_array(value) { return value == null ? [] : type(value) == 'array' ? uniq(value) : [value]; }
function get_cgroups_version() { return fixture.cgroup_version; }
function get_users() { return fixture.users; }
function get_groups() { return fixture.groups; }
function get_cgroups() { return fixture.cgroups; }
function load_profile() { return fixture.profile; }
function connect() { return {call: () => null}; }
function cursor() {
    return {
        load: () => null,
        get: (config, section, key) => fixture.config[section]?.[key],
        foreach: (config, section_type, callback) => {
            if (section_type == 'router_access_control') {
                for (let section in fixture.sections) callback(section);
            }
        }
    };
}
"""


def ucode_command():
    command = os.environ.get("NIKKI_TEST_UCODE_COMMAND")
    if command:
        command = json.loads(command)
        if not isinstance(command, list) or not command or not all(isinstance(part, str) for part in command):
            raise ValueError("NIKKI_TEST_UCODE_COMMAND must be a JSON command array")
        return command
    binary = shutil.which("ucode")
    return [binary] if binary else None


def section(**selectors):
    return {"enabled": "1", "proxy": "0", "dns": "0", **selectors}


class NikkiRouterSelectorPatchTest(unittest.TestCase):
    def test_matches_verified_device_template(self):
        self.assertEqual(hashlib.sha256(SOURCE.encode()).hexdigest(), "d6ecab87c26d3bc093aecd2832dcc26e860bd70cddc66d720e07742330aa78ab")

    def test_minimal_patch_is_idempotent_and_preserves_mode(self):
        with TemporaryDirectory() as directory:
            target = Path(directory) / "hijack.ut"
            target.write_text(SOURCE)
            target.chmod(0o755)
            patch(target)
            first = target.read_text()
            self.assertEqual(first, SOURCE.replace(OLD_BLOCK, NEW_BLOCK, 1))
            patch(target)
            self.assertEqual(first, target.read_text())
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_rejects_changed_collection_before_write(self):
        for original in (SOURCE.replace("index(cgroups, x)", "index(cgroups, x, 1)"), SOURCE + OLD_BLOCK, SOURCE.replace(WILDCARD, "{% if (new_selector_condition): %}", 1)):
            with self.subTest(original=original[-60:]), TemporaryDirectory() as directory:
                target = Path(directory) / "hijack.ut"
                target.write_text(original)
                with self.assertRaisesRegex(ValueError, "format changed"):
                    patch(target)
                self.assertEqual(target.read_text(), original)

    def test_rejects_partial_or_drifted_prior_patch(self):
        for original in (SOURCE + f"\n// {MARKER}\n", SOURCE.replace(OLD_BLOCK, NEW_BLOCK.replace("available_selectors > 0", "available_selectors >= 0"))):
            with self.subTest(original=original[-60:]), TemporaryDirectory() as directory:
                target = Path(directory) / "hijack.ut"
                target.write_text(original)
                with self.assertRaisesRegex(ValueError, "format changed"):
                    patch(target)
                self.assertEqual(target.read_text(), original)

    def test_rejects_symlink_without_modifying_target(self):
        with TemporaryDirectory() as directory:
            real = Path(directory) / "real.ut"
            real.write_text(SOURCE)
            link = Path(directory) / "hijack.ut"
            link.symlink_to(real)
            with self.assertRaisesRegex(ValueError, "regular file"):
                patch(link)
            self.assertEqual(real.read_text(), SOURCE)


@unittest.skipUnless(ucode_command(), "native ucode unavailable; patch integrity tests still run")
class NikkiRouterSelectorRenderTest(unittest.TestCase):
    def render(self, sections, mode="redirect", users=None, groups=None, cgroups=None, patched=True):
        with TemporaryDirectory() as directory:
            template = Path(directory) / "hijack.ut"
            template.write_text(SOURCE)
            if patched:
                patch(template)
            source = template.read_text().replace(IMPORTS, MOCKS, 1).replace("const fw4 = require('fw4');", "const fw4 = {hex: (value) => sprintf('0x%x', value)};", 1)
            template.write_text(source)
            fixture = Path(directory) / "fixture.json"
            fixture.write_text(json.dumps({
                "sections": sections,
                "users": users or ["root"], "groups": groups or ["root"], "cgroups": cgroups or [], "cgroup_version": 2,
                "profile": {"redir-port": 7892, "tproxy-port": 7893, "tun": {"enable": True, "device": "Mihomo"}, "dns": {"listen": "127.0.0.1:7895", "fake-ip-range": "198.18.0.0/16", "fake-ip-range6": "fc00::/18"}},
                "config": {"proxy": {"tcp_mode": mode, "udp_mode": mode, "ipv4_dns_hijack": "1", "ipv6_dns_hijack": "1", "ipv4_proxy": "1", "ipv6_proxy": "1", "router_proxy": "1", "lan_proxy": "0"}}
            }))
            result = subprocess.run(ucode_command() + ["-T", "-F", f"fixture={fixture}", str(template)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

    def chain(self, output, name):
        match = re.search(rf"^\tchain {name} \{{\n(.*?)^\t\}}", output, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, output)
        return match.group(1)

    def test_reproduces_unpatched_boot_bug(self):
        output = self.render([section(cgroup=["services/cpe5g-lucky-origin"])], patched=False)
        self.assertIn("counter return", self.chain(output, "router_redirect"))
        self.assertNotIn("socket cgroupv2", self.chain(output, "router_redirect"))

    def test_missing_explicit_service_never_becomes_global_bypass(self):
        for mode in ("redirect", "tproxy", "tun"):
            with self.subTest(mode=mode):
                output = self.render([section(cgroup=["services/lucky", "services/cpe5g-lucky-origin"])], mode=mode)
                self.assertEqual(self.chain(output, "router_dns_hijack").strip(), "")
                self.assertEqual(self.chain(output, f"router_{mode}").strip(), "")

    def test_missing_users_and_groups_also_skip_instead_of_wildcard(self):
        for selectors in ({"user": ["not-installed"]}, {"group": ["not-installed"]}, {"user": ["not-installed"], "group": ["not-installed"], "cgroup": ["services/missing"]}):
            with self.subTest(selectors=selectors):
                output = self.render([section(**selectors)])
                self.assertEqual(self.chain(output, "router_redirect").strip(), "")

    def test_one_available_service_remains_a_scoped_bypass(self):
        for mode in ("redirect", "tproxy", "tun"):
            with self.subTest(mode=mode):
                output = self.render([section(cgroup=["services/lucky", "services/cpe5g-lucky-origin"])], mode=mode, cgroups=["services/lucky"])
                for name in ("router_dns_hijack", f"router_{mode}"):
                    rules = self.chain(output, name)
                    self.assertIn('socket cgroupv2 level 2 "services/lucky"', rules)
                    self.assertNotIn("cpe5g-lucky-origin", rules)
                    self.assertEqual(len([line for line in rules.splitlines() if "counter" in line]), 1)

    def test_available_user_or_group_semantics_survive_missing_service(self):
        for selectors, expected in (({"user": ["root"], "cgroup": ["services/missing"]}, "meta skuid { root }"), ({"group": ["root"], "cgroup": ["services/missing"]}, "meta skgid { root }")):
            with self.subTest(selectors=selectors):
                output = self.render([section(**selectors)])
                self.assertIn(expected, self.chain(output, "router_redirect"))

    def test_intentional_selectorless_catchall_and_order_survive(self):
        output = self.render([section(cgroup=["services/missing"]), section(user=["root"]), section(proxy="1", dns="1")])
        rules = self.chain(output, "router_redirect")
        self.assertIn("meta skuid { root }", rules)
        self.assertIn("redirect to :7892", rules)
        self.assertLess(rules.index("meta skuid { root }"), rules.index("redirect to :7892"))
        self.assertEqual(len([line for line in rules.splitlines() if "counter" in line]), 2)

    def test_disabled_selectorless_section_remains_disabled(self):
        output = self.render([section(enabled="0")])
        self.assertEqual(self.chain(output, "router_redirect").strip(), "")


if __name__ == "__main__":
    unittest.main()
