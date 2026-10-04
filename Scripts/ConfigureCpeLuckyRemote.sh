#!/bin/sh
# Seed only a private, encrypted CPE B image; never echo bundle content.
set +x
set -eu
[ "$#" -eq 2 ] || { echo 'usage: ConfigureCpeLuckyRemote.sh <overlay> <true|false>' >&2; exit 1; }
SOURCE_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
exec python3 -B - "$1" "$2" "$SOURCE_DIR" <<'PY'
import base64
import binascii
import gzip
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile

MAX_BYTES = 256 * 1024
MAX_FILE = 64 * 1024
ALLOWED = {
    'etc/lucky/lucky_base.lkcf',
    'etc/lucky/lucky_ddns.lkcf',
    'etc/lucky/lucky_reverseproxy.lkcf',
    'etc/lucky/lucky_ssl.lkcf',
    'etc/lucky/lucky_ipfilter.lkcf',
    'etc/lucky/cert-sync/lucky.token',
    'etc/lucky/cert-sync/cpe5g-origin/current/fullchain.pem',
    'etc/lucky/cert-sync/cpe5g-origin/current/privkey.pem',
    'etc/lucky/cert-sync/cpe5g-origin/current/certificate-pin.json',
    'etc/cpe5g/public-origin.json',
    'etc/cpe5g-lucky/public-management.json',
    'etc/cpe5g-lucky/managed-native.json',
    'etc/cpe5g-lucky/api-service.json',
    'etc/cpe5g-lucky/tls/client-ca.pem',
    'etc/cpe5g-lucky/tls/health-client.crt',
    'etc/cpe5g-lucky/tls/health-client.key',
}
REQUIRED = ALLOWED - {'etc/lucky/lucky_ipfilter.lkcf', 'etc/cpe5g-lucky/api-service.json'}
DIRECTORIES = {str(parent) for name in ALLOWED for parent in PurePosixPath(name).parents
               if str(parent) != '.'}


class BundleError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise BundleError(message)


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        require(name not in result, 'duplicate JSON field')
        result[name] = value
    return result


def object_json(payload):
    try:
        data = json.loads(payload.decode('utf-8'), object_pairs_hook=unique_object)
    except (UnicodeError, ValueError):
        raise BundleError('invalid private JSON') from None
    require(isinstance(data, dict) and data, 'private JSON must be a nonempty object')
    return data


def decode_bundle(chunks):
    present = [index for index, chunk in enumerate(chunks) if chunk]
    require(all(chunks[index] for index in range(present[-1] + 1)), 'bundle chunks must be contiguous from 1')
    for chunk in chunks:
        require(len(chunk) <= 35000 and chunk.isascii(), 'bundle chunk exceeds ASCII size limit')
    try:
        compressed = base64.b64decode(''.join(chunks), validate=True)
    except (binascii.Error, ValueError):
        raise BundleError('bundle is not strict base64') from None
    require(0 < len(compressed) <= MAX_BYTES, 'decoded bundle size exceeds limit')
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
            raw = stream.read(MAX_BYTES + 1)
    except (OSError, EOFError):
        raise BundleError('bundle is not a valid gzip stream') from None
    require(0 < len(raw) <= MAX_BYTES, 'expanded bundle size exceeds limit')
    files = {}
    names = set()
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as archive:
            for index, member in enumerate(archive):
                require(index < 64, 'too many bundle members')
                name = member.name.rstrip('/') if member.isdir() else member.name
                path = PurePosixPath(name)
                require(name and not path.is_absolute() and '\\' not in name and
                        '..' not in path.parts and name == str(path), 'unsafe bundle member path')
                require(name not in names, 'duplicate bundle member')
                names.add(name)
                require(set(member.pax_headers) <= {'mtime', 'atime', 'ctime'} and member.sparse is None,
                        'extended path or sparse tar member refused')
                if member.isdir():
                    require(name in DIRECTORIES and member.size == 0, 'unexpected bundle directory')
                    continue
                require(member.isfile() and name in ALLOWED, 'unexpected or non-regular bundle member')
                require(0 < member.size <= MAX_FILE, 'bundle file size exceeds limit')
                stream = archive.extractfile(member)
                require(stream is not None, 'bundle member data missing')
                with stream:
                    payload = stream.read(MAX_FILE + 1)
                require(len(payload) == member.size, 'bundle member data size mismatch')
                files[name] = payload
            require(not any(raw[archive.offset:]), 'trailing nonzero tar data refused')
    except (tarfile.TarError, OSError, EOFError):
        raise BundleError('invalid bundle tar stream') from None
    require(REQUIRED <= set(files), 'required private seed files missing')
    require(sum(len(payload) for payload in files.values()) <= MAX_BYTES, 'private seed size exceeds limit')
    origin = object_json(files['etc/cpe5g/public-origin.json'])
    require(origin.get('enabled') is True and origin.get('hostname') == 'cpe.lucky.jmsu.top' and
            origin.get('source_policy') == 'mtls', 'public origin contract mismatch')
    require(isinstance(origin.get('client_ca_sha256'), str) and
            re.fullmatch('[a-fA-F0-9]{64}', origin['client_ca_sha256']), 'public origin client CA pin invalid')
    if 'server_cert_sha256' in origin:
        require(isinstance(origin['server_cert_sha256'], str) and
                re.fullmatch('[a-fA-F0-9]{64}', origin['server_cert_sha256']), 'legacy public origin server pin invalid')
    require(origin.get('allowed_sources', []) == [], 'mTLS origin cannot carry a source allowlist')
    certificate_pin = object_json(files['etc/lucky/cert-sync/cpe5g-origin/current/certificate-pin.json'])
    require(set(certificate_pin) == {'version', 'hostname', 'origin_sni', 'server_cert_sha256'},
            'certificate pin fields invalid')
    require(type(certificate_pin['version']) is int and certificate_pin['version'] == 1 and
            certificate_pin['hostname'] == 'cpe.lucky.jmsu.top' and
            certificate_pin['origin_sni'] == 'cpe-origin.jmsu.top', 'certificate pin contract mismatch')
    require(isinstance(certificate_pin['server_cert_sha256'], str) and
            re.fullmatch('[a-fA-F0-9]{64}', certificate_pin['server_cert_sha256']), 'certificate server pin invalid')
    validate_semantic_seed(files)
    return files


def validate_semantic_seed(files):
    # Use the production validators rather than a weaker parallel schema. Only
    # private JSON travels over stdin; argv is fixed code and a source directory.
    # The directory argv cannot match any imported module's CLI entry guard.
    manifest = object_json(files['etc/cpe5g-lucky/public-management.json'])
    managed = object_json(files['etc/cpe5g-lucky/managed-native.json'])
    validator = """
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
try {
  const source = process.argv[1];
  const {validateManifest} = await import(pathToFileURL(resolve(source, 'cpe5g-ipv6/lucky-origin.mjs')).href);
  const {validateManagedSeed} = await import(pathToFileURL(resolve(source, 'cpe5g-ipv6/reconcile-lucky-managed.mjs')).href);
  const data = JSON.parse(readFileSync(0, 'utf8'));
  validateManagedSeed(data.managed, validateManifest(data.manifest));
  if (data.api !== null) {
    const {validateApiService} = await import(pathToFileURL(resolve(source, 'cpe5g-ipv6/api-service-registry.mjs')).href);
    validateApiService(data.api);
  }
} catch {
  process.exitCode = 1;
}
"""
    try:
        result = subprocess.run(
            ['node', '--input-type=module', '--eval', validator, sys.argv[3]],
            input=json.dumps({'manifest': manifest, 'managed': managed,
                             'api': object_json(files['etc/cpe5g-lucky/api-service.json'])
                             if 'etc/cpe5g-lucky/api-service.json' in files else None}).encode('utf-8'),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LANG': 'C', 'LC_ALL': 'C'},
            timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise BundleError('shared private seed validator unavailable') from None
    require(result.returncode == 0, 'private Lucky semantic contract mismatch')


def open_directory(parent, name):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)


def validate_targets(root, files):
    for name in files:
        descriptor = os.dup(root)
        try:
            for part in PurePosixPath(name).parts[:-1]:
                try:
                    child = open_directory(descriptor, part)
                except FileNotFoundError:
                    break
                os.close(descriptor)
                descriptor = child
            else:
                try:
                    current = os.stat(PurePosixPath(name).name, dir_fd=descriptor, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                require(stat.S_ISREG(current.st_mode) and current.st_nlink == 1, 'unsafe existing private destination')
        finally:
            os.close(descriptor)


def private_directory(name):
    return any(name == prefix or name.startswith(prefix + '/')
               for prefix in ('etc/lucky', 'etc/cpe5g', 'etc/cpe5g-lucky'))


def install(overlay, files):
    root = os.open(overlay, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    created, changed_modes, installed = [], {}, []
    try:
        validate_targets(root, files)
        with tempfile.TemporaryDirectory(prefix='.cpe-lucky-seed-', dir=overlay) as temporary:
            stage = Path(temporary)
            stage.chmod(0o700)
            stage_fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                for index, name in enumerate(sorted(files)):
                    path = stage / (str(index) + '.new')
                    with path.open('xb') as stream:
                        stream.write(files[name])
                    path.chmod(0o600)
                try:
                    for index, name in enumerate(sorted(files)):
                        descriptor = os.dup(root)
                        label = ''
                        try:
                            for part in PurePosixPath(name).parts[:-1]:
                                label = part if not label else label + '/' + part
                                try:
                                    child = open_directory(descriptor, part)
                                except FileNotFoundError:
                                    os.mkdir(part, mode=0o700 if private_directory(label) else 0o755, dir_fd=descriptor)
                                    child = open_directory(descriptor, part)
                                    created.append(label)
                                    os.fchmod(child, 0o700 if private_directory(label) else 0o755)
                                if private_directory(label):
                                    value = os.fstat(child)
                                    identity = (value.st_dev, value.st_ino)
                                    if identity not in changed_modes:
                                        changed_modes[identity] = (os.dup(child), stat.S_IMODE(value.st_mode))
                                    os.fchmod(child, 0o700)
                                os.close(descriptor)
                                descriptor = child
                            filename = PurePosixPath(name).name
                            try:
                                value = os.stat(filename, dir_fd=descriptor, follow_symlinks=False)
                            except FileNotFoundError:
                                value = None
                            backup = str(index) + '.old' if value is not None else None
                            if value is not None:
                                require(stat.S_ISREG(value.st_mode) and value.st_nlink == 1,
                                        'private destination changed during install')
                                os.link(filename, backup, src_dir_fd=descriptor, dst_dir_fd=stage_fd,
                                        follow_symlinks=False)
                            os.replace(str(index) + '.new', filename, src_dir_fd=stage_fd, dst_dir_fd=descriptor)
                            installed.append((os.dup(descriptor), filename, backup))
                        finally:
                            os.close(descriptor)
                except BaseException:
                    for descriptor, filename, backup in reversed(installed):
                        if backup is None:
                            os.unlink(filename, dir_fd=descriptor)
                        else:
                            os.replace(backup, filename, src_dir_fd=stage_fd, dst_dir_fd=descriptor)
                    for descriptor, mode in changed_modes.values():
                        os.fchmod(descriptor, mode)
                    raise
            finally:
                os.close(stage_fd)
    except BaseException:
        for name in reversed(created):
            try:
                os.rmdir(name, dir_fd=root)
            except OSError:
                pass
        raise
    finally:
        for descriptor, _, _ in installed:
            os.close(descriptor)
        for descriptor, _ in changed_modes.values():
            os.close(descriptor)
        os.close(root)


def main():
    overlay, enable, source_directory = sys.argv[1:]
    require(enable in ('true', 'false'), 'invalid CPE enable input')
    chunks = [os.environ.get('CPE_LUCKY_REMOTE_BUNDLE_' + str(index), '') for index in range(1, 7)]
    if not any(chunks):
        print('CPE Lucky remote: no private seed requested')
        return
    require(enable == 'true' and os.environ.get('WRT_CPE_5G') == 'true' and
            os.environ.get('WRT_CPE_IPV6') == 'true' and
            os.environ.get('WRT_REQUIRED_DEVICE') == 'jdcloud_re-ss-01' and
            os.environ.get('WRT_ENCRYPT_ARTIFACT') == 'true', 'private seed requires encrypted RE-SS-01 CPE IPv6 build')
    files = decode_bundle(chunks)
    target = Path(overlay)
    require(target.is_dir() and not target.is_symlink(), 'overlay directory unavailable')
    for ancestor in target.absolute().parents:
        require(not ancestor.is_symlink(), 'symlink overlay ancestor refused')
    os.umask(0o077)
    install(target, files)
    print('CPE Lucky remote: private seed staged')


try:
    main()
except BundleError as error:
    print('ERROR: CPE Lucky private seed rejected: ' + str(error), file=sys.stderr)
    sys.exit(1)
except Exception:
    print('ERROR: CPE Lucky private seed could not be safely installed', file=sys.stderr)
    sys.exit(1)
PY
