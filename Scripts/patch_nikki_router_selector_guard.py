#!/usr/bin/env python3
"""Keep unavailable Nikki router selectors from becoming a catch-all rule.

Nikki filters users, groups and cgroups against the current system. A service
cgroup can legitimately be absent during boot; the resulting empty selector
list must not turn that service's bypass into a bypass for every process.
An intentionally selectorless section remains a catch-all, as upstream allows.
"""

import os
from pathlib import Path
import stat
import sys
import tempfile


MARKER = "hotwa: skip unavailable explicit router selectors"
OLD_BLOCK = """\tuci.foreach('nikki', 'router_access_control', (access_control) => {
\t\taccess_control['enabled'] = uci_bool(access_control['enabled']);
\t\taccess_control['user'] = filter(uci_array(access_control['user']), (x) => index(users, x) >= 0);
\t\taccess_control['group'] = filter(uci_array(access_control['group']), (x) => index(groups, x) >= 0);
\t\taccess_control['cgroup'] = filter(uci_array(access_control['cgroup']), (x) => index(cgroups, x) >= 0);
\t\taccess_control['proxy'] = uci_bool(access_control['proxy']);
\t\taccess_control['dns'] = uci_bool(access_control['dns']);
\t\tif (access_control['enabled']) {
\t\t\tpush(router_access_control, access_control);
\t\t}
\t});
"""
NEW_BLOCK = """\tuci.foreach('nikki', 'router_access_control', (access_control) => {
\t\t// hotwa: skip unavailable explicit router selectors
\t\tconst declared_selectors = length(uci_array(access_control['user'])) + length(uci_array(access_control['group'])) + length(uci_array(access_control['cgroup']));
\t\taccess_control['enabled'] = uci_bool(access_control['enabled']);
\t\taccess_control['user'] = filter(uci_array(access_control['user']), (x) => index(users, x) >= 0);
\t\taccess_control['group'] = filter(uci_array(access_control['group']), (x) => index(groups, x) >= 0);
\t\taccess_control['cgroup'] = filter(uci_array(access_control['cgroup']), (x) => index(cgroups, x) >= 0);
\t\taccess_control['proxy'] = uci_bool(access_control['proxy']);
\t\taccess_control['dns'] = uci_bool(access_control['dns']);
\t\tconst available_selectors = length(access_control['user']) + length(access_control['group']) + length(access_control['cgroup']);
\t\tif (access_control['enabled'] && (declared_selectors == 0 || available_selectors > 0)) {
\t\t\tpush(router_access_control, access_control);
\t\t}
\t});
"""
WILDCARD = "{% if (length(access_control['user']) == 0 && length(access_control['group']) == 0 && length(access_control['cgroup']) == 0): %}"


def patch(path: Path) -> None:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("Nikki router template must be a regular file")
    original = path.read_text(encoding="utf-8")
    if original.count(WILDCARD) != 4:
        raise ValueError("Nikki router template format changed: expected four router selector branches")
    if original.count(NEW_BLOCK) == 1 and original.count(OLD_BLOCK) == 0 and original.count(MARKER) == 1:
        return
    if original.count(OLD_BLOCK) != 1 or NEW_BLOCK in original or MARKER in original:
        raise ValueError("Nikki router template format changed: expected the reviewed selector collection")
    patched = original.replace(OLD_BLOCK, NEW_BLOCK, 1)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(patched)
            temporary.flush()
            os.fchmod(temporary.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_nikki_router_selector_guard.py <hijack.ut>")
    try:
        patch(Path(sys.argv[1]))
    except (OSError, ValueError) as error:
        raise SystemExit(f"ERROR: {error}")
