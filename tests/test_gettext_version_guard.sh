#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLES="$ROOT_DIR/Scripts/Handles.sh"

[ -f "$HANDLES" ] || { echo "missing Handles.sh"; exit 1; }

grep -q 'GETTEXT_MAKEFILE="./libs/gettext-full/Makefile"' "$HANDLES" || {
	echo "Handles.sh is missing the gettext-full Makefile path"
	exit 1
}

grep -q 'PKG_VERSION:=0\\\.24\\\.1' "$HANDLES" || {
	echo "Handles.sh does not detect the pinned gettext 0.24.1"
	exit 1
}

grep -q 'PKG_VERSION:=0.24.2' "$HANDLES" || {
	echo "Handles.sh does not bump gettext-full to 0.24.2"
	exit 1
}

grep -q 'GETTEXT_OLD_HASH="6164ec7aa61653ac9cdfb41d5c2344563b21f707da1562712e48715f1d2052a6"' "$HANDLES" || {
	echo "Handles.sh does not guard the gettext 0.24.1 tarball hash"
	exit 1
}

grep -q 'GETTEXT_NEW_HASH="fcc0187f597aef6bc5bc95c629db1126315beb196b20570eaec6a4941850f7c5"' "$HANDLES" || {
	echo "Handles.sh does not pin the gettext 0.24.2 tarball hash"
	exit 1
}

grep -q 'DEPENDS:=+libunistring +libxml2' "$HANDLES" || {
	echo "Handles.sh does not apply the upstream libintl-full DEPENDS fix"
	exit 1
}

echo "gettext version guard test passed"

# Exercise only the compatibility gate, without geodata downloads or other
# Handles mutations. Reviewed upstream recipes must stay unchanged; unknown
# versions and bad hashes must stop the build.
python3 - "$HANDLES" <<'PY'
import pathlib, subprocess, sys, tempfile
text = pathlib.Path(sys.argv[1]).read_text()
block = text[text.index('GETTEXT_MAKEFILE='):text.index('# 修复 gnulib stable-202501')]
old = '6164ec7aa61653ac9cdfb41d5c2344563b21f707da1562712e48715f1d2052a6'
new = 'fcc0187f597aef6bc5bc95c629db1126315beb196b20570eaec6a4941850f7c5'
current = '71132a3fb71e68245b8f2ac4e9e97137d3e5c02f415636eb508ae607bc01add7'
for version, digest, allowed in [('0.24.1', old, True), ('0.24.2', new, True),
                                  ('1.0', current, True), ('1.0', '0'*64, False),
                                  ('0.24.1', '0'*64, False), ('0.24.2', '0'*64, False),
                                  ('1.1', current, False)]:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        recipe = root/'libs/gettext-full/Makefile'
        recipe.parent.mkdir(parents=True)
        before = f'PKG_VERSION:={version}\nPKG_HASH:={digest}\n  URL:=https://www.gnu.org/software/gettext/\n'
        recipe.write_text(before)
        result = subprocess.run(['bash', '-eu', '-c', 'PKG_PATH="$PWD"\n'+block],
                                cwd=root, capture_output=True, text=True)
        assert (result.returncode == 0) == allowed, (version, digest, result.stderr)
        after = recipe.read_text()
        if allowed and version == '0.24.1':
            assert 'PKG_VERSION:=0.24.2\n' in after and f'PKG_HASH:={new}\n' in after
            assert 'DEPENDS:=+libunistring +libxml2' in after
        else:
            assert after == before, (version, 'recipe unexpectedly changed')
print('gettext compatibility fixtures: 7 passed')
PY
