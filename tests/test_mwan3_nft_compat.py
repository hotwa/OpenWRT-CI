#!/usr/bin/env python3
"""Focused mwan3 regression tests; kernel writes occur only in a fresh netns."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/mwan3"
HELPER = ROOT / "Scripts/cpe5g-mwan3-nft-compat"
PATCHER = ROOT / "Scripts/patch_mwan3_nft_compat.py"
LIB_SHA = "68bbc58eb102f40e5dad76fa7f022bdb646b641f033a5658ce5aaad59f024b0f"
INIT_SHA = "d3acea623135b44f54dc7c1b29423b5e2195705190fbe0ff66783625af38b01a"
JSON_SHA = "e9d783269b9dc65377f7d942b6a0e2ebd76987d4be4d3c21f462e6bae1b4b702"
IPT = {"ip": "/usr/sbin/iptables", "ip6": "/usr/sbin/ip6tables"}
NETNS_REASON = os.environ.get("CPE_MWAN3_NETNS_SKIP", "isolated network namespace unavailable")


def run(args, *, input=None, check=True, env=None):
    result = subprocess.run([str(x) for x in args], input=input, text=True,
                            capture_output=True, env=env, timeout=25)
    if check and result.returncode:
        raise AssertionError(f"{args!r} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def patched_pair(directory):
    lib = directory / "mwan3.sh"
    init = directory / "mwan3.init"
    shutil.copyfile(FIXTURES / "mwan3.sh", lib)
    shutil.copyfile(FIXTURES / "mwan3.init", init)
    run([sys.executable, "-B", PATCHER, lib, init])
    return lib, init


class SourceTests(unittest.TestCase):
    def test_public_fixtures_are_exact_pinned_sources(self):
        for name, digest in (("mwan3.sh", LIB_SHA), ("mwan3.init", INIT_SHA),
                             ("native-mangle.sanitized.json", JSON_SHA)):
            with self.subTest(fixture=name):
                self.assertEqual(hashlib.sha256((FIXTURES / name).read_bytes()).hexdigest(), digest)

    def test_patcher_cli_and_idempotence(self):
        with tempfile.TemporaryDirectory(prefix="mwan3-patch-") as tmp:
            lib, init = patched_pair(Path(tmp))
            before = (lib.read_bytes(), init.read_bytes())
            self.assertNotEqual(before[0], (FIXTURES / "mwan3.sh").read_bytes())
            self.assertNotEqual(before[1], (FIXTURES / "mwan3.init").read_bytes())
            run([sys.executable, "-B", PATCHER, lib, init])
            self.assertEqual((lib.read_bytes(), init.read_bytes()), before)

    def test_patcher_source_drift_never_partially_writes_pair(self):
        for drift in ("mwan3.sh", "mwan3.init"):
            with self.subTest(drift=drift), tempfile.TemporaryDirectory(prefix="mwan3-drift-") as tmp:
                directory = Path(tmp)
                lib, init = directory / "mwan3.sh", directory / "mwan3.init"
                shutil.copyfile(FIXTURES / "mwan3.sh", lib)
                shutil.copyfile(FIXTURES / "mwan3.init", init)
                with (directory / drift).open("a") as stream:
                    stream.write("\n# unexpected source drift\n")
                before = (lib.read_bytes(), init.read_bytes())
                result = run([sys.executable, "-B", PATCHER, lib, init], check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((lib.read_bytes(), init.read_bytes()), before)

    def test_raw_crlf_partial_patch_and_symlink_inputs_are_rejected(self):
        for kind in ("crlf", "partial-patch", "symlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="mwan3-raw-") as tmp:
                directory = Path(tmp)
                if kind == "partial-patch":
                    lib, init = patched_pair(directory)
                    lib.write_bytes(lib.read_bytes().replace(b"mwan3_nft_view()", b"mwan3_nft_view_broken()", 1))
                else:
                    lib, init = directory / "mwan3.sh", directory / "mwan3.init"
                    shutil.copyfile(FIXTURES / "mwan3.sh", lib)
                    shutil.copyfile(FIXTURES / "mwan3.init", init)
                    if kind == "crlf":
                        lib.write_bytes(lib.read_bytes().replace(b"\n", b"\r\n"))
                    else:
                        target = directory / "target"
                        lib.rename(target)
                        lib.symlink_to(target)
                before = (lib.read_bytes(), init.read_bytes())
                result = run([sys.executable, "-B", PATCHER, lib, init], check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((lib.read_bytes(), init.read_bytes()), before)


class MockTests(unittest.TestCase):
    """Always run JSON ownership guards, including on CI without CAP_SYS_ADMIN."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mwan3-mock-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.log = self.directory / "calls.jsonl"
        self.table = self.directory / "table.json"
        self.tables = self.directory / "tables.json"
        mock = """#!/usr/bin/python3
import json,os,pathlib,sys
args=sys.argv[1:]
binary=pathlib.Path(sys.argv[0]).name
body=sys.stdin.read() if args == ['-f','-'] else ''
with open(os.environ['MOCK_LOG'],'a') as log:
 log.write(json.dumps({'binary':binary,'args':args,'input':body})+'\\n')
if binary == 'nft':
 if args == ['-f','-']: sys.exit(0)
 if args[:3] == ['-j','list','table']:
  if os.environ.get('MOCK_ABSENT'): sys.exit(1)
  print(pathlib.Path(os.environ['MOCK_TABLE']).read_text()); sys.exit(0)
 if args == ['-j','list','tables']:
  print(pathlib.Path(os.environ['MOCK_TABLES']).read_text()); sys.exit(0)
 sys.exit(99)
if '-S' not in args: sys.exit(99)
index=args.index('-S')
if index == len(args)-1:
 if os.environ.get('MOCK_NORMAL'): print('-P PREROUTING ACCEPT'); sys.exit(0)
 sys.exit(1)
chain=args[index+1]
if chain == os.environ.get('MOCK_CHAIN_FAIL'): sys.exit(1)
print('-N '+chain+'\\n-A '+chain+' -j RETURN')
"""
        for name in ("nft", "iptables", "ip6tables"):
            path = self.directory / name
            path.write_text(mock)
            path.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.directory) + ":" + os.environ["PATH"],
                        MOCK_LOG=str(self.log), MOCK_TABLE=str(self.table), MOCK_TABLES=str(self.tables))
        self.tables.write_text('{"nftables":[]}')

    def inventory(self, family):
        rows = [{"table": {"family": family, "name": "mangle"}}]
        for chain in ("mwan3_hook", "mwan3_policy_existing", "foreign_keep"):
            rows.append({"chain": {"family": family, "table": "mangle", "name": chain}})
        for chain, handle in (("PREROUTING", 37), ("OUTPUT", 91)):
            rows.append({"rule": {"family": family, "table": "mangle", "chain": chain,
                                  "handle": handle, "expr": [{"counter": {"packets": 0, "bytes": 0}},
                                                             {"jump": {"target": "mwan3_hook"}}]}})
        fixture = json.loads((FIXTURES / "native-mangle.sanitized.json").read_text())
        rows.extend(row for row in fixture["nftables"] if "rule" in row
                    and row["rule"]["family"] == family
                    and not any("jump" in expr for expr in row["rule"]["expr"]))
        return {"nftables": rows}

    def helper(self, action, family):
        args = [HELPER, action, family]
        if action == "view":
            args += [family == "ip" and "iptables" or "ip6tables", "-w", "10", "-t", "mangle"]
        return run(args, check=False, env=self.env)

    def calls(self):
        return [json.loads(row) for row in self.log.read_text().splitlines()] if self.log.exists() else []

    def reset_log(self):
        self.log.unlink(missing_ok=True)

    def test_valid_inventory_fixed_check_and_exact_handle_removal(self):
        for family in IPT:
            with self.subTest(family=family):
                self.table.write_text(json.dumps(self.inventory(family)))
                self.reset_log()
                self.assertEqual(self.helper("check", family).returncode, 0)
                binary = "iptables" if family == "ip" else "ip6tables"
                self.assertTrue(any(row["binary"] == binary and row["args"] == ["-w", "10", "-t", "mangle", "-S"]
                                    for row in self.calls()))
                self.assertFalse(any(row["args"] == ["-f", "-"] for row in self.calls()))
                self.reset_log()
                self.assertEqual(self.helper("remove-hooks", family).returncode, 0)
                mutation = [row for row in self.calls() if row["args"] == ["-f", "-"]]
                self.assertEqual(len(mutation), 1)
                self.assertEqual(mutation[0]["input"],
                                 f"delete rule {family} mangle PREROUTING handle 37\n"
                                 f"delete rule {family} mangle OUTPUT handle 91\n")

    def test_wrong_family_duplicate_identity_and_malformed_json_reject(self):
        for family in IPT:
            valid = self.inventory(family)
            wrong = json.loads(json.dumps(valid))
            wrong["nftables"][0]["table"]["family"] = "ip6" if family == "ip" else "ip"
            duplicate = json.loads(json.dumps(valid))
            duplicate["nftables"].insert(0, duplicate["nftables"][0])
            missing = json.loads(json.dumps(valid))
            missing["nftables"].pop(0)
            for label, data in (("wrong-family", wrong), ("duplicate", duplicate), ("missing-identity", missing),
                                ("malformed", "{not-json")):
                with self.subTest(family=family, case=label):
                    self.table.write_text(data if isinstance(data, str) else json.dumps(data))
                    for action in ("check", "remove-hooks"):
                        self.reset_log()
                        self.assertNotEqual(self.helper(action, family).returncode, 0)
                        self.assertFalse(any(row["args"] == ["-f", "-"] for row in self.calls()))
                        self.assertFalse(any(row["binary"] != "nft" for row in self.calls()))

    def test_absence_requires_independent_valid_table_inventory(self):
        self.env["MOCK_ABSENT"] = "1"
        self.env["MOCK_NORMAL"] = "1"
        for family in IPT:
            with self.subTest(family=family):
                self.tables.write_text('{"nftables":[]}')
                self.assertEqual(self.helper("check", family).returncode, 0)
                self.assertEqual(self.helper("remove-hooks", family).returncode, 0)
                for data in ("{not-json", json.dumps({"nftables": [{"table": {"family": family, "name": "mangle"}}]}),
                             '{"nftables":[{"unknown":{}}]}', '{"nftables":[{"table":{}}]}'):
                    self.tables.write_text(data)
                    self.reset_log()
                    self.assertNotEqual(self.helper("check", family).returncode, 0)
                    self.assertFalse(any(row["args"] == ["-f", "-"] for row in self.calls()))

    def test_unsafe_reference_and_owned_chain_read_failure_publish_no_partial_view(self):
        for family in IPT:
            for reference in ("conditional", "goto", "foreign-chain"):
                with self.subTest(family=family, reference=reference):
                    data = self.inventory(family)
                    rule = data["nftables"][4]["rule"]
                    if reference == "conditional":
                        rule["expr"].insert(0, {"match": {"op": "==", "left": {"meta": {"key": "l4proto"}}, "right": "tcp"}})
                    elif reference == "goto":
                        rule["expr"][-1] = {"goto": {"target": "mwan3_hook"}}
                    else:
                        rule["chain"] = "foreign_keep"
                    self.table.write_text(json.dumps(data))
                    self.env["MOCK_NORMAL"] = "1"
                    for action in ("check", "remove-hooks"):
                        self.reset_log()
                        self.assertNotEqual(self.helper(action, family).returncode, 0)
                        self.assertFalse(any(row["args"] == ["-f", "-"] for row in self.calls()))
                    self.env.pop("MOCK_NORMAL")
            self.table.write_text(json.dumps(self.inventory(family)))
            self.env["MOCK_CHAIN_FAIL"] = "mwan3_policy_existing"
            result = self.helper("view", family)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.env.pop("MOCK_CHAIN_FAIL")

    def test_chain_name_ascii_grammar_without_jq_regex_support(self):
        real_jq = shutil.which("jq")
        self.assertTrue(real_jq)
        mock_jq = self.directory / "jq"
        mock_jq.write_text("""#!/usr/bin/python3
import os,re,sys
if any(re.search(r'\\b(test|match|capture|scan|sub|gsub|splits)\\s*\\(', arg) for arg in sys.argv[1:]):
 print('jq was compiled without ONIGURUMA',file=sys.stderr); sys.exit(3)
os.execv(os.environ['MOCK_REAL_JQ'],[os.environ['MOCK_REAL_JQ'],*sys.argv[1:]])
""")
        mock_jq.chmod(0o755)
        self.env["MOCK_REAL_JQ"] = real_jq
        for family in IPT:
            for name, accepted in (("mwan3_A09_.-foo", True), ("mwan3_", False),
                                   ("mwan3_foo bar", False), ("mwan3_foo/bar", False),
                                   ("mwan3_é", False), ("mwan3_🔥", False)):
                with self.subTest(family=family, name=name):
                    data = self.inventory(family)
                    data["nftables"][2]["chain"]["name"] = name
                    self.table.write_text(json.dumps(data))
                    for action in ("check", "remove-hooks"):
                        self.reset_log()
                        result = self.helper(action, family)
                        self.assertEqual(result.returncode == 0, accepted, result.stderr)
                        if not accepted:
                            self.assertFalse(any(row["args"] == ["-f", "-"] for row in self.calls()))


@unittest.skipUnless(os.environ.get("CPE_MWAN3_NETNS") == "1", NETNS_REASON)
class KernelTests(unittest.TestCase):
    def setUp(self):
        # Even an accidental --namespace invocation must never flush the host.
        self.assertNotEqual(os.readlink("/proc/self/ns/net"), os.environ.get("CPE_MWAN3_PARENT_NETNS"))
        self.assertTrue(os.environ.get("CPE_MWAN3_PARENT_NETNS"))
        self.tmp = tempfile.TemporaryDirectory(prefix="mwan3-nft-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.nft("flush ruleset")

    def nft(self, command):
        return run(["/usr/sbin/nft", "-f", "-"], input=command + "\n")

    def ipt(self, family, *args, check=True):
        return run([IPT[family], "-w", "-t", "mangle", *args], check=check)

    def helper(self, action, family, check=True):
        args = [HELPER, action, family]
        if action == "view":
            args += [IPT[family], "-w", "-t", "mangle"]
        return run(args, check=check)

    def snapshot(self):
        return [row for row in json.loads(run(["/usr/sbin/nft", "-j", "list", "ruleset"]).stdout)["nftables"]
                if "metainfo" not in row]

    def seed(self, family, mixed=True, reset=True):
        if reset:
            self.nft("flush ruleset")
        for chain in ("mwan3_hook", "mwan3_policy_existing", "foreign_keep", "foreign_mwan3_keep"):
            self.ipt(family, "-N", chain)
        self.ipt(family, "-A", "mwan3_hook", "-j", "mwan3_policy_existing")
        self.ipt(family, "-A", "mwan3_policy_existing", "-m", "comment", "--comment", "owned policy", "-j", "RETURN")
        for chain in ("foreign_keep", "foreign_mwan3_keep"):
            self.ipt(family, "-A", chain, "-m", "comment", "--comment", "foreign preserved", "-j", "RETURN")
        self.ipt(family, "-A", "PREROUTING", "-j", "foreign_keep")
        for chain in ("PREROUTING", "OUTPUT"):
            self.ipt(family, "-A", chain, "-j", "mwan3_hook")
        if reset:
            self.nft("add table inet foreign_table\nadd chain inet foreign_table foreign_chain\n"
                     "add rule inet foreign_table foreign_chain counter comment \"foreign table preserved\"")
        if mixed:
            fixture = json.loads((FIXTURES / "native-mangle.sanitized.json").read_text())
            rows = []
            for row in fixture["nftables"]:
                rule = row.get("rule", {})
                if rule.get("family") == family and not any("jump" in x for x in rule.get("expr", [])):
                    rule = {key: rule[key] for key in ("family", "table", "chain", "expr")}
                    rows.append({"insert": {"rule": rule}})
            self.assertEqual(len(rows), 2)
            run(["/usr/sbin/nft", "-j", "-f", "-"], input=json.dumps({"nftables": rows}))
            self.assertNotEqual(self.ipt(family, "-S", check=False).returncode, 0,
                                "fixture must reproduce native-expression full-table incompatibility")

    def foreign_snapshot(self):
        rows = []
        for row in self.snapshot():
            obj = row.get("chain", row.get("rule", {}))
            if obj.get("table") == "mangle" and obj.get("family") in IPT:
                if obj.get("name", obj.get("chain", "")).startswith("mwan3_"):
                    continue
                expr = obj.get("expr", [])
                if any(x.get("jump", {}).get("target") == "mwan3_hook" for x in expr):
                    continue
            rows.append(row)
        return rows

    def test_normal_view_is_exact_unmodified_iptables_output(self):
        for family in IPT:
            with self.subTest(family=family):
                self.seed(family, mixed=False)
                before = self.snapshot()
                self.assertEqual(self.helper("view", family).stdout, self.ipt(family, "-S").stdout)
                self.helper("check", family)
                self.assertEqual(self.snapshot(), before)

    def test_cold_absent_and_empty_mangle_tables_are_read_only(self):
        for family in IPT:
            for existing in (False, True):
                with self.subTest(family=family, existing=existing):
                    self.nft("flush ruleset")
                    if existing:
                        self.nft(f"add table {family} mangle")
                    before = self.snapshot()
                    self.helper("check", family)
                    self.helper("remove-hooks", family)
                    self.assertEqual(self.helper("view", family).stdout, self.ipt(family, "-S").stdout)
                    self.assertEqual(self.snapshot(), before)

    def test_general_and_iface_with_real_ipsets(self):
        if not shutil.which("ipset"):
            self.skipTest("ipset unavailable: real set-dependent general/create_iface paths require ipset")
        probe = run(["ipset", "create", "mwan3_fixture_probe", "hash:net"], check=False)
        if probe.returncode:
            self.skipTest("kernel ipset unavailable: " + probe.stderr.strip())
        run(["ipset", "destroy", "mwan3_fixture_probe"])
        self.seed("ip")
        self.seed("ip6", reset=False)
        for family in IPT:
            self.helper("remove-hooks", family)
            self.ipt(family, "-F", "mwan3_hook")
            self.ipt(family, "-X", "mwan3_hook")
        for config_family, set_family in (("ipv4", "inet"), ("ipv6", "inet6")):
            for chain in ("custom", "connected", "dynamic"):
                run(["ipset", "create", f"mwan3_{chain}_{config_family}", "hash:net", "family", set_family])
        before = self.foreign_snapshot()
        script = self.shell_environment() + """
mwan3_iface_tbl=' wan=1 5G=2 '
config_get() { local result="$4"; [ "$3" != family ] || result="$TEST_IFACE_FAMILY"; printf -v "$1" '%s' "$result"; }
mwan3_id2mask() { printf '0x%x\\n' "$(( ${!1} << 8 ))"; }
mwan3_set_general_iptables
mwan3_set_general_iptables
TEST_IFACE_FAMILY=ipv4
mwan3_create_iface_iptables wan eth0
mwan3_create_iface_iptables wan eth0
TEST_IFACE_FAMILY=ipv6
mwan3_create_iface_iptables 5G usb0
mwan3_create_iface_iptables 5G usb0
"""
        run(["/bin/bash", "-c", script])
        for family, iface in (("ip", "wan"), ("ip6", "5G")):
            view = self.helper("view", family).stdout.splitlines()
            for base in ("PREROUTING", "OUTPUT"):
                self.assertEqual(view.count(f"-A {base} -j mwan3_hook"), 1)
            chain = f"mwan3_iface_in_{iface}"
            self.assertEqual(view.count("-N " + chain), 1)
            self.assertEqual(sum(line.startswith("-A " + chain + " ") for line in view), 4)
        self.assertEqual(self.foreign_snapshot(), before)

    def test_mixed_view_has_owned_chain_contents_and_only_unconditional_base_hooks(self):
        for family in IPT:
            with self.subTest(family=family):
                self.seed(family)
                before = self.snapshot()
                view = self.helper("view", family).stdout.splitlines()
                for chain in ("mwan3_hook", "mwan3_policy_existing"):
                    self.assertEqual(view.count("-N " + chain), 1)
                    self.assertIn("-N " + chain, self.ipt(family, "-S", chain).stdout.splitlines())
                for chain in ("PREROUTING", "OUTPUT"):
                    self.assertIn(f"-A {chain} -j mwan3_hook", view)
                self.assertTrue(any(x.startswith("-A mwan3_policy_existing ") and "owned policy" in x for x in view))
                self.assertFalse(any("foreign" in x for x in view))
                self.helper("check", family)
                self.assertEqual(self.snapshot(), before)

    def test_remove_hooks_preserves_all_foreign_objects_and_is_idempotent(self):
        for family in IPT:
            with self.subTest(family=family):
                self.seed(family)
                self.ipt(family, "-A", "PREROUTING", "-j", "mwan3_hook")
                before = self.foreign_snapshot()
                owned_before = self.ipt(family, "-S", "mwan3_hook").stdout
                self.helper("remove-hooks", family)
                self.assertEqual(self.foreign_snapshot(), before)
                self.assertEqual(self.ipt(family, "-S", "mwan3_hook").stdout, owned_before)
                self.assertFalse(any(x.get("jump", {}).get("target") == "mwan3_hook"
                                     for row in self.snapshot() if "rule" in row
                                     and row["rule"]["chain"] in ("PREROUTING", "OUTPUT")
                                     for x in row["rule"]["expr"]))
                after = self.snapshot()
                self.helper("remove-hooks", family)
                self.assertEqual(self.snapshot(), after)

    def test_conditional_goto_and_foreign_references_reject_before_any_delete(self):
        expressions = (
            ("OUTPUT", "meta l4proto tcp counter jump mwan3_hook"),
            ("OUTPUT", "counter goto mwan3_hook"),
            ("OUTPUT", "jump mwan3_hook"),
            ("OUTPUT", "limit rate 1/second counter jump mwan3_hook"),
            ("foreign_keep", "counter jump mwan3_policy_existing"),
        )
        for family in IPT:
            for chain, expression in expressions:
                with self.subTest(family=family, expression=expression):
                    self.seed(family)
                    self.nft(f"add rule {family} mangle {chain} {expression}")
                    before = self.snapshot()
                    for action in ("check", "remove-hooks"):
                        self.assertNotEqual(self.helper(action, family, check=False).returncode, 0)
                        self.assertEqual(self.snapshot(), before)

    def test_check_rejects_foreign_owned_reference_even_when_full_iptables_view_succeeds(self):
        for family in IPT:
            with self.subTest(family=family):
                self.seed(family, mixed=False)
                self.ipt(family, "-A", "foreign_keep", "-p", "tcp", "-j", "mwan3_hook")
                self.ipt(family, "-S")
                before = self.snapshot()
                self.assertNotEqual(self.helper("check", family, check=False).returncode, 0)
                self.assertNotEqual(self.helper("remove-hooks", family, check=False).returncode, 0)
                self.assertEqual(self.snapshot(), before)

    def shell_environment(self):
        lib, init = patched_pair(self.directory)
        root = self.directory / "root"
        for name in ("usr/share/libubox/jshn.sh", "lib/mwan3/common.sh", "lib/functions/network.sh"):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("")
        # Redirect only the installed helper pathname in the temporary patched fixture.
        text = lib.read_text()
        for installed in ("/usr/libexec/cpe5g-mwan3-nft-compat", "/usr/sbin/cpe5g-mwan3-nft-compat"):
            text = text.replace(installed, str(HELPER))
        lib.write_text(text)
        shutil.copyfile(lib, root / "lib/mwan3/mwan3.sh")
        dumps = self.directory / "dumps"
        dumps.mkdir()
        preamble = f"""
export IPKG_INSTROOT={str(root)!r}
. {str(lib)!r}
. {str(init)!r}
IPT4='/usr/sbin/iptables -w -t mangle'
IPT6='/usr/sbin/ip6tables -w -t mangle'
IPT4R='/usr/sbin/iptables-restore -w --noflush'
IPT6R='/usr/sbin/ip6tables-restore -w --noflush'
NO_IPV6=0
MMX_MASK=0x3f00
MMX_DEFAULT=0x3f00
MMX_BLACKHOLE=0x3d00
MMX_UNREACHABLE=0x3e00
MWAN3_STATUS_IPTABLES_LOG_DIR={str(dumps)!r}
MWAN3_STATUS_DIR={str(self.directory / 'status')!r}
MWAN3TRACK_STATUS_DIR={str(self.directory / 'track')!r}
MWAN3_INTERFACE_MAX=250
mwan3_init() {{ :; }}
config_get() {{ local result="$4"; [ "$3" != last_resort ] || result="$TEST_LAST_RESORT"; printf -v "$1" '%s' "$result"; }}
config_list_foreach() {{ :; }}
config_foreach() {{ :; }}
LOG() {{ if [ "$1" = error ]; then printf '%s\\n' "$*" >&2; exit 99; fi; }}
"""
        return preamble

    def test_patched_source_policy_creation_update_and_status_in_mixed_tables(self):
        self.seed("ip")
        self.seed("ip6", reset=False)
        before = self.foreign_snapshot()
        preamble = self.shell_environment()
        script = preamble + """
TEST_LAST_RESORT=default
mwan3_create_policies_iptables cpe5g_failover
TEST_LAST_RESORT=blackhole
mwan3_create_policies_iptables cpe5g_failover
mwan3_report_policies_v4
mwan3_report_policies_v6
"""
        result = run(["/bin/bash", "-c", script])
        self.assertEqual(result.stdout.count("cpe5g_failover:"), 2)
        self.assertEqual(result.stdout.count(" blackhole"), 2)
        for family in IPT:
            policy = self.ipt(family, "-S", "mwan3_policy_cpe5g_failover").stdout
            self.assertEqual(policy.count("-N mwan3_policy_cpe5g_failover"), 1)
            self.assertIn("--comment blackhole", policy)
            self.assertNotIn("--comment default", policy)
        self.assertEqual(self.foreign_snapshot(), before)

    def test_patched_source_weighted_members_failover_and_status(self):
        self.seed("ip")
        self.seed("ip6", reset=False)
        before = self.foreign_snapshot()
        preamble = self.shell_environment() + """
mwan3_iface_tbl=' wan=1 5G=2 '
config_get() {
 local result="$4"
 case "$2.$3" in
  wm.interface) result=wan;; cm.interface) result=5G;;
  wm.metric) result=1;; cm.metric) result="$TEST_BACKUP_METRIC";;
  wm.weight) result=3;; cm.weight) result=1;;
  wan.family|5G.family) result="$TEST_FAMILY";;
  *.last_resort) result=unreachable;;
 esac
 printf -v "$1" '%s' "$result"
}
config_list_foreach() { "$3" wm; "$3" cm; }
network_get_device() { if [ "$2" = wan ]; then printf -v "$1" eth0; else printf -v "$1" usb0; fi; }
mwan3_get_iface_hotplug_state() { if [ "$1" = wan ]; then echo "$TEST_WAN_STATE"; else echo "$TEST_CELL_STATE"; fi; }
mwan3_id2mask() { printf '0x%x\\n' "$(( ${!1} << 8 ))"; }
"""
        for family, config_family in (("ip", "ipv4"), ("ip6", "ipv6")):
            with self.subTest(family=family):
                reporter = "mwan3_report_policies_v" + ("4" if family == "ip" else "6")
                script = preamble + f"""
TEST_FAMILY={config_family}
TEST_BACKUP_METRIC=1
TEST_WAN_STATE=online
TEST_CELL_STATE=online
mwan3_create_policies_iptables cpe5g_failover
echo WEIGHTED
{reporter}
TEST_BACKUP_METRIC=2
mwan3_create_policies_iptables cpe5g_failover
echo PRIMARY
{reporter}
TEST_WAN_STATE=offline
mwan3_create_policies_iptables cpe5g_failover
echo CELL
{reporter}
TEST_CELL_STATE=offline
mwan3_create_policies_iptables cpe5g_failover
echo OFFLINE
{reporter}
mwan3_create_policies_iptables cpe5g_failover
"""
                output = run(["/bin/bash", "-c", script]).stdout
                weighted = output.split("WEIGHTED\n", 1)[1].split("PRIMARY\n", 1)[0]
                primary = output.split("PRIMARY\n", 1)[1].split("CELL\n", 1)[0]
                cell = output.split("CELL\n", 1)[1].split("OFFLINE\n", 1)[0]
                offline = output.split("OFFLINE\n", 1)[1]
                self.assertIn(" wan (75%)", weighted)
                self.assertIn(" 5G (25%)", weighted)
                self.assertIn(" wan (100%)", primary)
                self.assertNotIn(" 5G (", primary)
                self.assertIn(" 5G (100%)", cell)
                self.assertNotIn(" wan (", cell)
                self.assertIn(" unreachable", offline)
                self.assertNotIn(" out ", offline)
                policy = self.ipt(family, "-S", "mwan3_policy_cpe5g_failover").stdout
                self.assertEqual(policy.count("-N mwan3_policy_cpe5g_failover"), 1)
                self.assertEqual(policy.count("--comment unreachable"), 1)
        self.assertEqual(self.foreign_snapshot(), before)

    def test_patched_stop_cleans_owned_chains_but_preserves_foreign_objects(self):
        for family in IPT:
            with self.subTest(family=family):
                self.seed(family)
                before = self.foreign_snapshot()
                preamble = self.shell_environment()
                # Empty route/rule/ipset inventories and no sleeps; nft operations remain real.
                script = preamble + """
IP4=true
IP6=true
IPS=true
sleep() { :; }
stop_service
stop_service
"""
                run(["/bin/bash", "-c", script])
                self.assertEqual(self.foreign_snapshot(), before)
                self.assertFalse(any(row.get("chain", {}).get("name", "").startswith("mwan3_")
                                     for row in self.snapshot()))
                # Each subtest receives a new source-fixture tree.
                shutil.rmtree(self.directory / "root")
                shutil.rmtree(self.directory / "dumps")

    def test_patched_stop_preflights_both_families_before_shutdown_routes_or_rules(self):
        marker = self.directory / "mutation"
        preamble = self.shell_environment() + f"""
config_foreach() {{ echo shutdown >> {str(marker)!r}; }}
IP4='echo route-mutation'
IP6='echo route-mutation'
IPS=true
sleep() {{ echo sleep >> {str(marker)!r}; }}
"""
        for family in IPT:
            for service in ("stop_service", "start_service"):
                with self.subTest(family=family, service=service):
                    self.seed("ip", mixed=False)
                    self.seed("ip6", mixed=False, reset=False)
                    # Full -S succeeds; the second-family preflight must still reject.
                    self.ipt(family, "-A", "foreign_keep", "-p", "tcp", "-j", "mwan3_hook")
                    self.ipt(family, "-S")
                    before = self.snapshot()
                    result = run(["/bin/bash", "-c", preamble + service], check=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(marker.exists())
                    self.assertNotIn("route-mutation", result.stdout)
                    self.assertEqual(self.snapshot(), before)


def main():
    if "--no-netns" in sys.argv:
        sys.argv.remove("--no-netns")
        KernelTests.__unittest_skip__ = True
        KernelTests.__unittest_skip_why__ = "kernel tests disabled for source/mock-only verification"
        unittest.main(verbosity=2)
        return
    if "--namespace" in sys.argv:
        sys.argv.remove("--namespace")
        parent = os.environ.get("CPE_MWAN3_PARENT_NETNS")
        if not parent or parent == os.readlink("/proc/self/ns/net"):
            raise SystemExit("Refusing kernel tests outside a newly created network namespace")
        os.environ["CPE_MWAN3_NETNS"] = "1"
        # The decorator is evaluated before main; explicitly enable the runtime tests.
        KernelTests.__unittest_skip__ = False
        unittest.main(verbosity=2)
        return
    dependencies = ("unshare", "nft", "iptables", "ip6tables", "iptables-restore", "ip6tables-restore", "jq")
    missing = [name for name in dependencies if not shutil.which(name)]
    if not missing:
        env = os.environ.copy()
        env["CPE_MWAN3_PARENT_NETNS"] = os.readlink("/proc/self/ns/net")
        probe = run(["/usr/bin/unshare", "-n", "true"], check=False)
        if probe.returncode == 0:
            raise SystemExit(subprocess.call(["/usr/bin/unshare", "-n", sys.executable, "-B", __file__, "--namespace"], env=env))
        reason = probe.stderr.strip()
    else:
        reason = "missing kernel-test dependencies: " + ", ".join(missing)
    KernelTests.__unittest_skip_why__ = reason
    unittest.main(verbosity=2)


if __name__ == "__main__":
    main()
