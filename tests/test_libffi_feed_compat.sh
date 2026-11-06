#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$ROOT" <<'PY'
import importlib.util
from pathlib import Path
import sys
import tempfile

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('compat', repo/'Scripts/ensure_libffi_recipe.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
recipe = (repo/'Scripts/compat/libffi/Makefile').read_bytes()
assert b'$(PKG_INSTALL_DIR)/usr/include/*.h' in recipe
assert b'$(eval $(call HostBuild))' in recipe
assert b'$(eval $(call BuildPackage,libffi))' in recipe
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root/'include').mkdir()
    (root/'include/package.mk').touch()
    assert mod.ensure(root)
    assert (root/'package/libs/libffi/Makefile').read_bytes() == recipe
    assert not mod.ensure(root)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root/'include').mkdir()
    (root/'include/package.mk').touch()
    upstream = root/'feeds/packages/libs/libffi/Makefile'
    upstream.parent.mkdir(parents=True)
    upstream.write_text('define Package/libffi\n  TITLE:=upstream\nendef\n')
    assert not mod.ensure(root)
    assert not (root/'package/libs/libffi').exists()
    assert 'upstream' in upstream.read_text()
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root/'include').mkdir()
    (root/'include/package.mk').touch()
    (root/'package/libs/libffi').mkdir(parents=True)
    try:
        mod.ensure(root)
    except ValueError:
        pass
    else:
        raise AssertionError('incomplete package directory was overwritten')
workflow = (repo/'.github/workflows/WRT-CORE.yml').read_text()
assert workflow.index('ensure_libffi_recipe.py" "$PWD"') < workflow.index('retry_cmd 5 15 ./scripts/feeds install -a')
assert 'compat/libffi/Makefile' in workflow
print('libffi feed-to-core compatibility checks passed')
PY
