#!/usr/bin/env python3
# age tool binaries are trusted inputs: production obtains them with FetchAge.sh.
# This Linux helper is non-interactive; identities must work without a prompt.
# Output parents/ancestors must be trusted against concurrent local replacement.
# Encryption plus hashes protects confidentiality/integrity, not CI provenance.
import base64, ctypes, hashlib, json, os, re, shutil, stat, subprocess, sys, tarfile, tempfile
VERSION = 'v1.3.2'
AGE_RELEASE_SHA256 = 'cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10'
AGE_RELEASE_URL = 'https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-linux-amd64.tar.gz'
MAX_SUM_BYTES = 1024 * 1024
MAX_FILES = 2048
MAX_BYTES = 32 * 1024 ** 3

class ArtifactError(Exception):
    pass

def require(ok, message):
    if not ok:
        raise ArtifactError(message)

def safe_path(raw):
    require(bool(raw) and '..' not in raw.split(os.sep), 'unsafe path')
    path = os.path.abspath(raw)
    require(path != os.sep, 'unsafe path')
    current = os.sep
    for component in path.split(os.sep)[1:]:
        current = os.path.join(current, component)
        if os.path.lexists(current):
            require(not stat.S_ISLNK(os.lstat(current).st_mode), 'symlink path refused')
    return path

def regular(path):
    s = os.lstat(path)
    require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1, 'non-regular or linked input refused')
    return s

def file_input(raw):
    path = safe_path(raw)
    regular(path)
    return path

def directory_input(raw):
    path = safe_path(raw)
    require(stat.S_ISDIR(os.lstat(path).st_mode), 'input directory unavailable')
    return path

def output_path(raw, source=None):
    path = safe_path(raw)
    require(not os.path.lexists(path), 'output already exists')
    require(os.path.isdir(os.path.dirname(path)), 'output parent unavailable')
    if source:
        require(os.path.commonpath([path, source]) != source, 'output is inside input')
    return path

def safe_name(name):
    return bool(name) and len(name.encode('utf-8')) <= 240 and (name not in ('.', '..')) and (not name.startswith('-')) and ('/' not in name) and ('\\' not in name) and all((ord(c) >= 32 and ord(c) != 127 for c in name))

def flat_files(directory):
    entries = list(os.scandir(directory))
    require(0 < len(entries) <= MAX_FILES, 'invalid payload file count')
    total = 0
    for entry in entries:
        require(safe_name(entry.name), 'unsafe filename')
        total += regular(entry.path).st_size
    require(total <= MAX_BYTES, 'payload too large')
    return sorted((entry.name for entry in entries))

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as src:
        for block in iter(lambda : src.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def sums_text(directory, names):
    return ''.join((digest(os.path.join(directory, name)) + '  ' + name + '\n' for name in sorted(names)))

def check_sums(directory, names):
    require('SHA256SUMS' in names, 'SHA256SUMS missing')
    expected = set(names) - {'SHA256SUMS'}
    require(bool(expected), 'empty payload')
    require(regular(os.path.join(directory, 'SHA256SUMS')).st_size <= MAX_SUM_BYTES, 'checksum manifest too large')
    text = open(os.path.join(directory, 'SHA256SUMS'), encoding='utf-8').read()
    require(text.endswith('\n'), 'non-canonical checksum manifest')
    seen = set()
    for line in text.splitlines():
        match = re.fullmatch('([A-Fa-f0-9]{64})  (.+)', line)
        require(match is not None, 'malformed checksum manifest')
        (sha, name) = match.groups()
        require(safe_name(name) and name in expected and (name not in seen), 'checksum coverage mismatch')
        require(digest(os.path.join(directory, name)) == sha.lower(), 'checksum mismatch')
        seen.add(name)
    require(seen == expected, 'checksum coverage mismatch')

def private_write(path, data):
    with open(path, 'xb') as dst:
        dst.write(data)
    os.chmod(path, 0o600)

def copy_flat(source, names, dest):
    # Pin the source directory and bound reads, including concurrent growth.
    total = 0
    directory_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in names:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
            try:
                size = os.fstat(fd)
                require(stat.S_ISREG(size.st_mode) and size.st_nlink == 1, 'input changed type')
                total += size.st_size
                require(total <= MAX_BYTES, 'copied payload too large')
                with os.fdopen(os.dup(fd), 'rb') as src, open(os.path.join(dest, name), 'xb') as dst:
                    remaining = size.st_size
                    while remaining:
                        block = src.read(min(remaining, 1024 * 1024))
                        require(bool(block), 'input changed size')
                        dst.write(block)
                        remaining -= len(block)
                    require(src.read(1) == b'', 'input changed size')
            finally:
                os.close(fd)
            os.chmod(os.path.join(dest, name), 0o600)
    finally:
        os.close(directory_fd)

def age_binary(raw):
    path = file_input(raw)
    require(os.access(path, os.X_OK), 'age is not executable')
    result = subprocess.run([path, '--version'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
    require(result.returncode == 0 and result.stdout.decode('ascii').strip() == VERSION, 'age version mismatch')
    return path

def run_age(args):
    result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=600)
    require(result.returncode == 0, 'age operation failed')

def publish(stage, output):
    # Linux NOREPLACE publication happens only after all validation succeeds.
    libc = ctypes.CDLL(None, use_errno=True)
    require(hasattr(libc, 'renameat2'), 'atomic no-replace rename unavailable')
    result = libc.renameat2(-100, os.fsencode(stage), -100, os.fsencode(output), 1)
    require(result == 0, 'output publish refused')

def recipient_key(raw):
    path = file_input(raw)
    require(regular(path).st_size <= 65536, 'recipient file too large')
    lines = [line.strip() for line in open(path, encoding='utf-8') if line.strip() and (not line.lstrip().startswith('#'))]
    require(len(lines) == 1, 'exactly one recipient is required')
    parts = lines[0].split()
    require(len(parts) >= 2 and parts[0] == 'ssh-ed25519', 'SSH Ed25519 recipient required')
    blob = base64.b64decode(parts[1], validate=True)
    require(len(blob) == 51 and blob[:4] == b'\x00\x00\x00\x0b' and (blob[4:15] == b'ssh-ed25519') and (blob[15:19] == b'\x00\x00\x00 '), 'malformed SSH Ed25519 recipient')
    key = 'ssh-ed25519 ' + base64.b64encode(blob).decode('ascii')
    fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(blob).digest()).decode('ascii').rstrip('=')
    return (key, fingerprint)

def fetch(args):
    require(len(args) == 1, 'usage: FetchAge.sh OUTPUT_DIR')
    require(sys.platform.startswith('linux') and os.uname().machine == 'x86_64', 'Linux amd64 is required')
    output = output_path(args[0])
    parent = os.path.dirname(output)
    url = AGE_RELEASE_URL
    expected = AGE_RELEASE_SHA256
    with tempfile.TemporaryDirectory(prefix='.cpe5g-age-', dir=parent) as stage:
        archive = os.path.join(stage, 'age.tar.gz')
        result = subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2', '--retry', '2', '--connect-timeout', '20', '--max-time', '240', url, '--output', archive], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=800)
        require(result.returncode == 0, 'age download failed')
        require(digest(archive) == expected, 'age archive checksum mismatch')
        with tarfile.open(archive, 'r:gz') as tar:
            members = tar.getmembers()
            require(len(members) <= 16, 'unexpected age archive')
            for member in members:
                require(not member.name.startswith('/') and '..' not in member.name.split('/') and (not member.issym()) and (not member.islnk()), 'unsafe age archive')
            binary = tar.getmember('age/age')
            require(binary.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and binary.sparse is None and (0 < binary.size < 64 * 1024 ** 2), 'invalid age binary')
            tool = os.path.join(stage, 'age')
            private_write(tool, tar.extractfile(binary).read())
            os.chmod(tool, 0o755)
        age_binary(tool)
        os.unlink(archive)
        publish(stage, output)

def encrypt(args):
    require(len(args) == 4, 'usage: EncryptFirmwareArtifact.sh AGE_BINARY PAYLOAD_DIR RECIPIENT_FILE OUTPUT_DIR')
    age = age_binary(args[0])
    payload = directory_input(args[1])
    (key, fingerprint) = recipient_key(args[2])
    output = output_path(args[3], payload)
    names = flat_files(payload)
    if 'SHA256SUMS' in names:
        require(regular(os.path.join(payload, 'SHA256SUMS')).st_size <= MAX_SUM_BYTES, 'checksum manifest too large')
    require('SHA256SUMS' in names or os.environ.get('CPE5G_ARTIFACT_TEST_ALLOW_MISSING_SUMS') == '1', 'SHA256SUMS missing')
    with tempfile.TemporaryDirectory(prefix='cpe5g-artifact-plaintext-') as private, tempfile.TemporaryDirectory(prefix='.cpe5g-envelope-', dir=os.path.dirname(output)) as stage:
        copied = os.path.join(private, 'payload')
        os.mkdir(copied, 0o700)
        copy_flat(payload, names, copied)
        if 'SHA256SUMS' not in names:
            private_write(os.path.join(copied, 'SHA256SUMS'), sums_text(copied, names).encode('utf-8'))
            names = sorted(names + ['SHA256SUMS'])
        check_sums(copied, names)
        archive = os.path.join(private, 'firmware.tar')
        with tarfile.open(archive, 'w', format=tarfile.GNU_FORMAT) as tar:
            for name in names:
                file = os.path.join(copied, name)
                info = tarfile.TarInfo(name)
                info.size = os.stat(file).st_size
                info.mode = 0o600
                info.uid = info.gid = 0
                info.mtime = 0
                with open(file, 'rb') as src:
                    tar.addfile(info, src)
        cipher = os.path.join(stage, 'firmware.tar.age')
        run_age([age, '--encrypt', '--recipient', key, '--output', cipher, archive])
        os.chmod(cipher, 0o600)
        metadata = {'format': 'cpe5g-age-envelope-v1', 'age_version': VERSION, 'age_release_archive_sha256': AGE_RELEASE_SHA256, 'payload': 'firmware.tar.age', 'recipient_type': 'ssh-ed25519', 'recipient_ssh_fingerprint': fingerprint}
        private_write(os.path.join(stage, 'ENCRYPTION.json'), (json.dumps(metadata, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8'))
        private_write(os.path.join(stage, 'SHA256SUMS'), sums_text(stage, ['firmware.tar.age', 'ENCRYPTION.json']).encode('utf-8'))
        check_sums(stage, flat_files(stage))
        publish(stage, output)

def decrypt(args):
    require(len(args) == 4, 'usage: DecryptFirmwareArtifact.sh AGE_BINARY ENVELOPE_DIR IDENTITY_FILE OUTPUT_DIR')
    age = age_binary(args[0])
    envelope = directory_input(args[1])
    identity = file_input(args[2])
    output = output_path(args[3], envelope)
    require(regular(identity).st_size <= 1024 * 1024, 'identity file too large')
    names = flat_files(envelope)
    require(set(names) == {'firmware.tar.age', 'ENCRYPTION.json', 'SHA256SUMS'}, 'unexpected envelope files')
    require(regular(os.path.join(envelope, 'SHA256SUMS')).st_size <= MAX_SUM_BYTES, 'checksum manifest too large')
    require(regular(os.path.join(envelope, 'ENCRYPTION.json')).st_size <= 65536, 'encryption metadata too large')
    with tempfile.TemporaryDirectory(prefix='cpe5g-artifact-decrypt-') as private, tempfile.TemporaryDirectory(prefix='.cpe5g-clear-', dir=os.path.dirname(output)) as stage:
        checked = os.path.join(private, 'envelope')
        os.mkdir(checked, 0o700)
        copy_flat(envelope, names, checked)
        check_sums(checked, names)
        require(os.stat(os.path.join(checked, 'ENCRYPTION.json')).st_size <= 65536, 'encryption metadata too large')

        def unique_pairs(pairs):
            result = {}
            for (key, value) in pairs:
                require(key not in result, 'duplicate metadata field')
                result[key] = value
            return result
        metadata = json.load(open(os.path.join(checked, 'ENCRYPTION.json'), encoding='utf-8'), object_pairs_hook=unique_pairs)
        expected = {'format': 'cpe5g-age-envelope-v1', 'age_version': VERSION, 'age_release_archive_sha256': AGE_RELEASE_SHA256, 'payload': 'firmware.tar.age', 'recipient_type': 'ssh-ed25519'}
        require(isinstance(metadata, dict) and set(metadata) == set(expected) | {'recipient_ssh_fingerprint'}, 'invalid encryption metadata')
        require(all((metadata.get(k) == v for (k, v) in expected.items())), 'encryption metadata mismatch')
        require(re.fullmatch('SHA256:[A-Za-z0-9+/]{43}', metadata.get('recipient_ssh_fingerprint', '')) is not None, 'invalid recipient fingerprint')
        archive = os.path.join(private, 'firmware.tar')
        run_age([age, '--decrypt', '--identity', identity, '--output', archive, os.path.join(checked, 'firmware.tar.age')])
        require(os.stat(archive).st_size <= MAX_BYTES + MAX_FILES * 4096, 'archive too large')
        with tarfile.open(archive, 'r:') as tar:
            seen = set()
            total = 0
            members = []
            for member in tar:
                require(len(members) < MAX_FILES and safe_name(member.name) and (member.name not in seen), 'unsafe or duplicate tar entry')
                require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and member.sparse is None and (not member.pax_headers), 'non-regular tar entry refused')
                require(member.size >= 0, 'invalid tar entry size')
                if member.name == 'SHA256SUMS':
                    require(member.size <= MAX_SUM_BYTES, 'checksum manifest too large')
                total += member.size
                require(total <= MAX_BYTES, 'tar payload too large')
                seen.add(member.name)
                members.append(member)
            require('SHA256SUMS' in seen, 'SHA256SUMS missing')
            for member in members:
                with tar.extractfile(member) as src, open(os.path.join(stage, member.name), 'xb') as dst:
                    shutil.copyfileobj(src, dst, 1024 * 1024)
                os.chmod(os.path.join(stage, member.name), 0o600)
        check_sums(stage, flat_files(stage))
        publish(stage, output)

def main():
    commands = {'fetch': fetch, 'encrypt': encrypt, 'decrypt': decrypt}
    require(len(sys.argv) > 1 and sys.argv[1] in commands, 'expected fetch, encrypt or decrypt command')
    commands[sys.argv[1]](sys.argv[2:])
if __name__ == '__main__':
    try:
        main()
    except ArtifactError as error:
        print('ERROR: firmware artifact: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print('ERROR: firmware artifact operation failed', file=sys.stderr)
        sys.exit(1)
