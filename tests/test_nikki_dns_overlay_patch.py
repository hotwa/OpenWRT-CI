from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from Scripts.patch_nikki_dns_overlay import patch


MERGE = ". as $item ireduce ({}; . * $item )"
SOURCE = f"""#!/bin/sh
if [ "$overwrite_fake_ip_filter" = 1 ]; then
    yq -M -i 'del(.dns.fake-ip-filter)' "$RUN_PROFILE_PATH"
fi
if [ "$overwrite_dns_nameserver_policy" = 1 ]; then
    yq -M -i 'del(.dns.nameserver-policy)' "$RUN_PROFILE_PATH"
fi
yq ea '{MERGE}' "$RUN_PROFILE_PATH" -
yq ea '{MERGE}' "$RUN_PROFILE_PATH" "$MIXIN_FILE_PATH" -
"""


class NikkiDnsOverlayPatchTest(unittest.TestCase):
    def test_preserves_subscription_dns_and_is_idempotent(self):
        with TemporaryDirectory() as directory:
            target = Path(directory) / "nikki"
            target.write_text(SOURCE)
            patch(target)
            first = target.read_text()
            patch(target)
            self.assertEqual(first, target.read_text())
            self.assertNotIn("del(.dns.fake-ip-filter)", first)
            self.assertNotIn("del(.dns.nameserver-policy)", first)
            self.assertEqual(first.count("$prior.dns.fake-ip-filter"), 2)
            self.assertEqual(first.count("| unique"), 2)

    def test_rejects_unknown_upstream_init_format_without_modifying_it(self):
        with TemporaryDirectory() as directory:
            target = Path(directory) / "nikki"
            changed = SOURCE.replace(MERGE, "new upstream merge")
            target.write_text(changed)
            with self.assertRaisesRegex(ValueError, "Nikki init format changed"):
                patch(target)
            self.assertEqual(changed, target.read_text())


if __name__ == "__main__":
    unittest.main()
