"""Offline contracts: no GitHub API or device access is needed for these tests."""

import importlib.util
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/cnb_upstream_report.py"
spec = importlib.util.spec_from_file_location("cnb_upstream_report", SCRIPT)
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class UpstreamReportTests(unittest.TestCase):
    def test_rejects_missing_conflicting_or_movable_pin(self):
        good = ("WRT_REPO: https://github.com/VIKINGYFY/immortalwrt.git\n"
                "WRT_BRANCH: main\nWRT_COMMIT: " + "a" * 40 + "\n")
        self.assertEqual(reporter.source_pin(good)["pin"], "a" * 40)
        for text in (good.replace("a" * 40, "main"),
                     good + "WRT_COMMIT: " + "b" * 40 + "\n",
                     good.replace("VIKINGYFY", "attacker"),
                     good.replace("WRT_COMMIT", "NOT_A_COMMIT")):
            with self.subTest(text=text[-55:]), self.assertRaises(ValueError):
                reporter.source_pin(text)

    def test_fixed_pin_and_nss_path_are_compared_without_mutation(self):
        pin = "a" * 40
        head = "b" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for filename in reporter.WORKFLOWS.values():
                path = root / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("WRT_REPO: https://github.com/VIKINGYFY/immortalwrt.git\n"
                                "WRT_BRANCH: main\nWRT_COMMIT: " + pin + "\n", encoding="utf-8")
            requested = []

            def fetch(path):
                requested.append(path)
                if "/commits?" in path:
                    args = parse_qs(urlsplit("https://api.github.com/" + path).query)
                    # NSS changed; other paths did not (regardless of ref).
                    sha = pin if args["path"][0] != "package/qca-nss" or args["sha"][0] == pin else head
                    return [{"sha": sha}]
                return {"sha": head}

            actual = reporter.report(fetch, root)
            self.assertTrue(actual["devices"]["RE-CS-07"]["source_advanced"])
            self.assertTrue(actual["devices"]["RE-CS-07"]["paths"]["package/qca-nss"]["changed"])
            self.assertFalse(actual["devices"]["CPE-5G"]["paths"]["target/linux/qualcommax"]["changed"])
            self.assertEqual(len(requested), 17)
            self.assertEqual(sorted(p.name for p in root.rglob("*")),
                             sorted([Path(p).name for p in reporter.WORKFLOWS.values()] + ["workflows", ".github"]))

    def test_refuses_invalid_api_sha_and_conflicting_production_branches(self):
        with self.assertRaises(ValueError):
            reporter.checked_sha("main")
        with self.assertRaises(ValueError):
            reporter.source_pin("WRT_REPO: https://github.com/VIKINGYFY/immortalwrt.git\n"
                                "WRT_BRANCH: main;echo-danger\nWRT_COMMIT: " + "a" * 40)


if __name__ == "__main__":
    unittest.main()
