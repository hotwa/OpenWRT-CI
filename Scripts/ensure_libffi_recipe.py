#!/usr/bin/env python3
"""Bridge the libffi feed-to-core move for older exact source pins."""
import hashlib
from pathlib import Path
import re
import shutil
import sys


def ensure(root):
    root = Path(root).resolve()
    if not (root / 'include/package.mk').is_file():
        raise ValueError('OpenWrt source root unavailable')
    provider = re.compile(r'^define Package/libffi\s*$', re.M)
    for base in (root / 'package', root / 'feeds'):
        for recipe in base.rglob('Makefile'):
            if provider.search(recipe.read_text(errors='replace')):
                print('libffi provider already present; leaving upstream recipe unchanged')
                return False
    recipe = Path(__file__).parent / 'compat/libffi/Makefile'
    data = recipe.read_bytes()
    if hashlib.sha256(data).hexdigest() != 'cec8456f8958a8b4e8af2bcca944600827d29c64f0b59fabf833599864e3c12f':
        raise ValueError('reviewed compatibility recipe checksum mismatch')
    if not provider.search(data.decode()):
        raise ValueError('compatibility recipe is not a libffi provider')
    dest = root / 'package/libs/libffi'
    if dest.exists():
        raise ValueError('incomplete libffi directory exists; refusing overwrite')
    dest.mkdir(parents=True)
    shutil.copyfile(recipe, dest / 'Makefile')
    print('Installed reviewed libffi compatibility recipe (OpenWrt 9b835ec6264f)')
    return True


if __name__ == '__main__':
    try:
        ensure(sys.argv[1])
    except (OSError, ValueError, IndexError) as error:
        print('libffi compatibility setup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
