from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from Scripts.patch_nikki_cron_self_restart import patch


SOURCE = '''#!/bin/sh
procd_close_instance
if [ "$reload_cron" = 1 ]; then
\t\t/etc/init.d/cron restart
fi
service_stopped() { cleanup; }
cleanup() {
  sed -i "/#nikki/d" /etc/crontabs/root
\t\t/etc/init.d/cron restart
}
'''


class NikkiCronSelfRestartPatchTest(unittest.TestCase):
    def test_removes_both_cron_restarts_and_is_idempotent(self):
        with TemporaryDirectory() as directory:
            target = Path(directory) / "nikki.init"
            target.write_text(SOURCE)
            patch(target)
            first = target.read_text()
            patch(target)
            self.assertEqual(target.read_text(), first)
            self.assertNotIn("/etc/init.d/cron restart", first)
            self.assertEqual(first.count("procd watches /etc/crontabs/root"), 2)
            self.assertIn('sed -i "/#nikki/d"', first)

    def test_rejects_unknown_upstream_layout_without_writing(self):
        with TemporaryDirectory() as directory:
            target = Path(directory) / "nikki.init"
            changed = SOURCE.replace("/etc/init.d/cron restart", "service cron reload", 1)
            target.write_text(changed)
            with self.assertRaisesRegex(ValueError, "layout changed"):
                patch(target)
            self.assertEqual(target.read_text(), changed)


if __name__ == "__main__":
    unittest.main()
