#!/usr/bin/env python3
"""Preserve subscription DNS entries when Nikki applies its UCI mixin.

Nikki's upstream init script deletes two complete DNS fields before merging
the UCI mixin. Keep the subscription policy map and merge its fake-IP filter
with the UCI entries instead. An upstream change must be reviewed explicitly.
"""

from pathlib import Path
import sys


DELETE_FILTER = "yq -M -i 'del(.dns.fake-ip-filter)' \"$RUN_PROFILE_PATH\""
DELETE_POLICY = "yq -M -i 'del(.dns.nameserver-policy)' \"$RUN_PROFILE_PATH\""
OLD_MERGE = ". as $item ireduce ({}; . * $item )"
NEW_MERGE = (
    ". as $item ireduce ({}; . as $prior | . * $item | "
    ".dns.fake-ip-filter = "
    "((($prior.dns.fake-ip-filter // []) + "
    "($item.dns.fake-ip-filter // [])) | unique))"
)


def patch(path: Path) -> None:
    original = path.read_text()
    if NEW_MERGE in original and DELETE_FILTER not in original and DELETE_POLICY not in original:
        return
    expected = {DELETE_FILTER: 1, DELETE_POLICY: 1, OLD_MERGE: 2}
    for snippet, count in expected.items():
        actual = original.count(snippet)
        if actual != count:
            raise ValueError(f"Nikki init format changed: expected {count} occurrences, got {actual}")
    patched = original.replace(DELETE_FILTER, ": # Keep subscription fake-IP filters for union")
    patched = patched.replace(DELETE_POLICY, ": # Keep subscription DNS policy for matcher overlay")
    patched = patched.replace(OLD_MERGE, NEW_MERGE)
    path.write_text(patched)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_nikki_dns_overlay.py <nikki init script>")
    patch(Path(sys.argv[1]))
