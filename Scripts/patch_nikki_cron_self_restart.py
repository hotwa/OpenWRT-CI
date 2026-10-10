#!/usr/bin/env python3
"""Avoid killing a cron-launched Nikki restart with cron's own cgroup.

Nikki edits /etc/crontabs/root while stopping and starting. OpenWrt's cron
procd instance watches that file, so an explicit cron restart is unnecessary.
When Nikki was itself launched by cron, that restart kills the caller's cgroup
before Nikki can reach its start phase. Fail closed if upstream changes shape.
"""

from pathlib import Path
import sys


CRON_RESTART = "\t\t/etc/init.d/cron restart"
REPLACEMENT = "\t\t: # procd watches /etc/crontabs/root; do not kill cron's caller"


def patch(path: Path) -> None:
    original = path.read_text()
    if CRON_RESTART not in original and original.count(REPLACEMENT) == 2:
        return
    if original.count(CRON_RESTART) != 2 or REPLACEMENT in original:
        raise ValueError("Nikki init cron-restart layout changed")
    for marker in ('sed -i "/#nikki/d"', 'procd_close_instance', 'service_stopped()'):
        if marker not in original:
            raise ValueError(f"Nikki init missing expected marker: {marker}")
    path.write_text(original.replace(CRON_RESTART, REPLACEMENT))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_nikki_cron_self_restart.py <nikki init script>")
    patch(Path(sys.argv[1]))
