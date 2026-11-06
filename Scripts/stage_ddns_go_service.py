#!/usr/bin/env python3
"""Check the DDNS service contract and keep its credentials private."""
from pathlib import Path
import re
import sys


def stage(files):
    files = Path(files)
    source = files.parent / 'package/luci-app-ddns-go/ddns-go/files/ddns-go.init'
    text = source.read_text()
    expected = [
        r'(?m)^CONFDIR=/etc/ddns-go\s*$',
        r'(?m)^CONF=\$CONFDIR/ddns-go-config\.yaml\s*$',
        r"config_foreach\s+start_instance\s+['\"]basic['\"]",
        r'procd_set_param\s+user\s+ddns-go',
        r'chown\s+-R\s+ddns-go:ddns-go\s+"\$CONFDIR"',
    ]
    if not all(re.search(pattern, text) for pattern in expected):
        raise ValueError('DDNS init contract changed; review the seed and service together')
    for old, new in [('chmod 755 "$CONFDIR"', 'chmod 700 "$CONFDIR"'),
                     ('chmod 644 "$CONF"', 'chmod 600 "$CONF"')]:
        if text.count(old) == 1:
            text = text.replace(old, new)
        elif text.count(new) != 1:
            raise ValueError('DDNS init permission contract changed')
    target = files / 'etc/init.d/ddns-go'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    target.chmod(0o755)
    print('DDNS basic section and private service permissions validated')


if __name__ == '__main__':
    try:
        stage(sys.argv[1])
    except (OSError, ValueError, IndexError) as error:
        print('DDNS service staging failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
