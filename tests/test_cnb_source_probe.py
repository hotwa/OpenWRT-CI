"""Source-only probe must preserve fixed SHA and never access deployment APIs."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CnbSourceProbeTests(unittest.TestCase):
    def test_pinned_public_source_only_and_no_device_actions(self):
        text = (ROOT / "Scripts/cnb_source_probe.sh").read_text(encoding="utf-8")
        for required in (
            "unset CNB_TOKEN GITHUB_TOKEN GH_TOKEN",
            "cnb_re_profile_preflight.py",
            "[ \"$resolved\" = \"$pin\" ]",
            "git clone --depth=1 --single-branch --branch main",
            "git -C \"$source_dir\" fetch --depth=1 origin \"$pin\"",
            "./scripts/feeds update -a",
            "./scripts/feeds install -a",
            "aptx_retry install -y git perl ca-certificates rsync gawk",
            "[ -s ./tmp/.packageinfo ] && [ -s ./tmp/.targetinfo ]",
            "source directory already exists; refuse reuse",
        ):
            self.assertIn(required, text)
        for forbidden in ("sysupgrade", "ssh root@", "scp ", "HEADSCALE_OPENWRT_AUTHKEY",
                          "SAMBA_DEFAULT_PASSWORD", "imports:", "make -j", "docker push"):
            self.assertNotIn(forbidden, text)


if __name__ == "__main__":
    unittest.main()
