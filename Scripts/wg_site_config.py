#!/usr/bin/env python3
"""Validate and stage a private WG seed; never print credential values."""
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def stage(root, role):
    os.umask(0o077)
    if role not in ('server', 'client'):
        raise ValueError('invalid role')
    def required(name):
        value = os.environ.get(name, '')
        if not value or any(c in value for c in '\r\n\x00'):
            raise ValueError('missing or invalid ' + name)
        return value
    def key(name):
        value = required(name)
        if len(base64.b64decode(value, validate=True)) != 32:
            raise ValueError('invalid WireGuard key length')
        return value
    private, peer = key('WG_PRIV_KEY'), key('WG_PEER_PUB')
    result = subprocess.run(
        ['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
        input=bytes.fromhex('302e020100300506032b656e04220420') + base64.b64decode(private),
        capture_output=True, check=True)
    if len(result.stdout) != 44:
        raise ValueError('WireGuard public key derivation failed')
    local_public = base64.b64encode(result.stdout[-32:]).decode()
    if peer == local_public:
        raise ValueError('peer key equals local identity; check per-device secret mapping')
    if os.environ.get('U2R_ENABLE', '0') != '0':
        raise ValueError('TCP carrier is not validated; keep U2R_ENABLE=0')
    domain = required('DDNSGO_DOMAIN').lower()
    endpoint = os.environ.get('DDNS_HOST', '').lower()
    pattern = r'(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}'
    if not re.fullmatch(pattern, domain) or (role == 'client' and not re.fullmatch(pattern, endpoint)):
        raise ValueError('invalid DDNS hostname')
    if role == 'server' and endpoint:
        raise ValueError('server must learn the client endpoint')
    ak, sk = required('DDNSGO_AK'), required('DDNSGO_SK')
    # These two fixed sites are intentionally scoped, not an arbitrary LAN publisher.
    remote = '192.168.11.0/24' if role == 'server' else '192.168.12.0/24'
    config = dict(ROLE=role, WG_IF='wg0', WG_PRIV_KEY=private,
                  WG_LOCAL_PUB=local_public, WG_PEER_PUB=peer,
                  WG_LISTEN_PORT='51820', TUN_PREFIX='10.99.0',
                  WG_TUN_NET='10.99.0.0/30', WG_REMOTE_NET=remote,
                  WG_TUN_PEER_IP='10.99.0.2' if role == 'server' else '10.99.0.1',
                  DDNS_HOST=endpoint, KEEPALIVE='10', MAX_HANDSHAKE_AGE='900',
                  TABLE_WG='60', U2R_ENABLE='0')
    ipaddress.ip_network(remote)
    root = Path(root)
    site = root / 'etc/wg-site/site.conf'
    site.parent.mkdir(parents=True, exist_ok=True)
    site.write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in config.items()))
    site.chmod(0o600)
    ddns = root / 'etc/ddns-go/ddns-go-config.yaml'
    ddns.parent.mkdir(parents=True, exist_ok=True)
    # JSON is valid YAML; quoting safely retains punctuation in credentials.
    ddns.write_text(json.dumps(dict(dnsconf=[dict(name='aliyun-wg-site',
        ipv4=dict(enable=True, gettype='netInterface', url='',
                  netinterface=os.environ.get('DDNSGO_NETINTERFACE', 'pppoe-wan'),
                  cmd='', domains=[domain]),
        ipv6=dict(enable=False, domains=[]), dns=dict(name='alidns', id=ak, secret=sk,
        extparam=''), ttl='600', httpinterface='')], notallowwanaccess=True), indent=2) + '\n')
    ddns.chmod(0o600)
    uci = root / 'etc/config/ddns-go'
    uci.parent.mkdir(parents=True, exist_ok=True)
    uci.write_text("config basic 'ddns-go'\n\toption enabled '1'\n\toption port '9876'\n\toption time '300'\n\toption logger '1'\n\toption skipverify '0'\n")
    uci.chmod(0o600)
    print('Validated private WG/DDNS seed: role=' + role)


if __name__ == '__main__':
    try:
        stage(*sys.argv[1:])
    except Exception as exc:
        # Neither exception repr nor command stderr is safe with credential inputs.
        print('WG seed validation failed: ' + (str(exc) if isinstance(exc, ValueError)
                                             else type(exc).__name__), file=sys.stderr)
        sys.exit(1)
