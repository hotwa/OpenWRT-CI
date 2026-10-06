#!/usr/bin/env python3
"""Patch only the pinned CPE mwan3 package's shared-mangle readers/cleanup.

The original and reconstructed already-patched source hashes are mandatory.
Both inputs are validated before either file is changed. Other device presets
must not invoke this patcher.
"""
from hashlib import sha256
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

LIB_SHA256 = '68bbc58eb102f40e5dad76fa7f022bdb646b641f033a5658ce5aaad59f024b0f'
INIT_SHA256 = 'd3acea623135b44f54dc7c1b29423b5e2195705190fbe0ff66783625af38b01a'
MARKER = 'hotwa: CPE shared nft mangle compatibility'
LIB_ANCHOR = '. "${IPKG_INSTROOT}/lib/mwan3/common.sh"\n'
FUNCTIONS = '''
# hotwa: CPE shared nft mangle compatibility
mwan3_nft_family()
{
	if [ "$1" = "$IPT4" ]; then
		echo ip
	elif [ "$1" = "$IPT6" ]; then
		echo ip6
	else
		return 1
	fi
}

mwan3_nft_view()
{
	local family command
	family="$(mwan3_nft_family "$1")" || return 1
	command=$1
	# IPT4/IPT6 are upstream command strings, expanded exactly as upstream.
	/usr/libexec/cpe5g-mwan3-nft-compat view "$family" $command
}

mwan3_nft_check()
{
	local family
	family="$(mwan3_nft_family "$1")" || return 1
	/usr/libexec/cpe5g-mwan3-nft-compat check "$family"
}

mwan3_nft_remove_hooks()
{
	local family
	family="$(mwan3_nft_family "$1")" || return 1
	/usr/libexec/cpe5g-mwan3-nft-compat remove-hooks "$family"
}
'''
READ_ERROR = '{ LOG error "CPE mwan3 shared mangle view unavailable"; return 1; }'
OLD_STOP = '''		table="$($IPT -S)"
		{
			echo "*mangle";
			[ -z "${table##*PREROUTING -j mwan3_hook*}" ] && echo "-D PREROUTING -j mwan3_hook"
			[ -z "${table##*OUTPUT -j mwan3_hook*}" ] && echo "-D OUTPUT -j mwan3_hook"
			echo "$table" | awk '{print "-F "$2}' | grep mwan3 | sort -u
			echo "$table" | awk '{print "-X "$2}' | grep mwan3 | sort -u
			echo "COMMIT"
		} | $IPTR
'''
NEW_STOP = '''		table="$(mwan3_nft_view "$IPT")" || { LOG error "CPE mwan3 shared mangle view unavailable"; return 1; }
		mwan3_nft_remove_hooks "$IPT" || { LOG error "CPE mwan3 hook removal unavailable"; return 1; }
		{
			echo "*mangle";
			echo "$table" | awk '$1 == "-N" && $2 ~ /^mwan3_/ {print "-F "$2}' | sort -u
			echo "$table" | awk '$1 == "-N" && $2 ~ /^mwan3_/ {print "-X "$2}' | sort -u
			echo "COMMIT"
		} | $IPTR || { LOG error "CPE mwan3 owned chain removal unavailable"; return 1; }
'''
PREFLIGHT = '''	# hotwa: CPE shared nft mangle compatibility
	# Check every active family before stopping trackers or changing routes.
	mwan3_nft_check "$IPT4" || { LOG error "CPE mwan3 shared IPv4 mangle unavailable"; return 1; }
	if [ $NO_IPV6 -eq 0 ]; then
		mwan3_nft_check "$IPT6" || { LOG error "CPE mwan3 shared IPv6 mangle unavailable"; return 1; }
	fi
'''


def digest(text):
    return sha256(text.encode('utf-8')).hexdigest()


def patch_lib(source):
    if digest(source) != LIB_SHA256:
        raise ValueError('mwan3 library source drift from pinned CPE 2.12.2-r1')
    source = source.replace(LIB_ANCHOR, LIB_ANCHOR + FUNCTIONS, 1)
    pattern = r'(?m)^(\t+)current="\$\(\$IPT -S\)"\$\'\\n\'$'
    source, count = re.subn(pattern, lambda m: m[1] + 'current="$(mwan3_nft_view "$IPT")" || ' + READ_ERROR + '\n' + m[1] + 'current="$current"$\'\\n\'', source)
    if count != 5:
        raise ValueError('mwan3 library reader locations changed')
    old = '\t$IPT -S | grep -q "^-A mwan3_rules.*-i $device" && return'
    new = '\tcurrent="$(mwan3_nft_view "$IPT")" || ' + READ_ERROR + '\n\techo "$current" | grep -q "^-A mwan3_rules.*-i $device" && return'
    if source.count(old) != 1:
        raise ValueError('mwan3 user interface reader changed')
    source = source.replace(old, new)
    for family in ('4', '6'):
        old = '\tfor policy in $($IPT' + family + ' -S | awk \'{print $2}\' | grep mwan3_policy_ | sort -u); do'
        new = '\tlocal table\n\ttable="$(mwan3_nft_view "$IPT' + family + '")" || ' + READ_ERROR + '\n\tfor policy in $(echo "$table" | awk \'{print $2}\' | grep mwan3_policy_ | sort -u); do'
        if source.count(old) != 1:
            raise ValueError('mwan3 policy inventory reader changed')
        source = source.replace(old, new)
    return source


def patch_init(source):
    if digest(source) != INIT_SHA256:
        raise ValueError('mwan3 init source drift from pinned CPE 2.12.2-r1')
    if source.count(OLD_STOP) != 1:
        raise ValueError('mwan3 stop cleanup changed')
    source = source.replace(OLD_STOP, NEW_STOP)
    # mwan3_init resolves commands/NO_IPV6; preflight precedes every tracker,
    # route/rule, chain and ipset mutation performed by these service methods.
    for name in ('start_service', 'stop_service'):
        pattern = r'(' + name + r'\(\) \{\n[\s\S]*?\n\tmwan3_init\n)'
        source, count = re.subn(pattern, lambda m: m[1] + PREFLIGHT, source, count=1)
        if count != 1:
            raise ValueError('mwan3 service entry changed')
    return source


def original_lib(source):
    source = source.replace(LIB_ANCHOR + FUNCTIONS, LIB_ANCHOR, 1)
    pattern = r'(?m)^(\t+)current="\$\(mwan3_nft_view "\$IPT"\)" \|\| ' + re.escape(READ_ERROR) + r'\n\1current="\$current"\$\'\\n\'$'
    source = re.sub(pattern, lambda m: m[1] + 'current="$($IPT -S)"$\'\\n\'', source)
    source = source.replace('\tcurrent="$(mwan3_nft_view "$IPT")" || ' + READ_ERROR + '\n\techo "$current" | grep -q "^-A mwan3_rules.*-i $device" && return', '\t$IPT -S | grep -q "^-A mwan3_rules.*-i $device" && return')
    for family in ('4', '6'):
        new = '\tlocal table\n\ttable="$(mwan3_nft_view "$IPT' + family + '")" || ' + READ_ERROR + '\n\tfor policy in $(echo "$table" | awk \'{print $2}\' | grep mwan3_policy_ | sort -u); do'
        old = '\tfor policy in $($IPT' + family + ' -S | awk \'{print $2}\' | grep mwan3_policy_ | sort -u); do'
        source = source.replace(new, old)
    return source


def original_init(source):
    return source.replace(PREFLIGHT, '').replace(NEW_STOP, OLD_STOP)


def validated(source, expected, reverse, forward):
    if digest(source) == expected:
        return forward(source)
    original = reverse(source)
    if digest(original) != expected or forward(original) != source:
        raise ValueError('mwan3 source drift or incomplete prior compatibility patch')
    return source


def transform(lib_source, init_source):
    return (validated(lib_source, LIB_SHA256, original_lib, patch_lib),
            validated(init_source, INIT_SHA256, original_init, patch_init))


def patch(lib_path: Path, init_path: Path):
    paths = (Path(lib_path), Path(init_path))
    metadata = [path.lstat() for path in paths]
    if any(not stat.S_ISREG(item.st_mode) for item in metadata):
        raise ValueError('mwan3 patch inputs must be regular files')
    original = [path.read_bytes().decode('utf-8') for path in paths]
    results = transform(*original)
    staged = []
    try:
        for path, info, before, after in zip(paths, metadata, original, results):
            if before == after:
                continue
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, prefix='.' + path.name + '.', delete=False) as output:
                temporary = Path(output.name)
                staged.append((temporary, path))
                output.write(after)
                output.flush()
                os.fchmod(output.fileno(), stat.S_IMODE(info.st_mode))
                os.fsync(output.fileno())
        for temporary, path in staged:
            os.replace(temporary, path)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: patch_mwan3_nft_compat.py <mwan3.sh> <mwan3-init>')
    try:
        patch(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError) as error:
        raise SystemExit('ERROR: ' + str(error))
