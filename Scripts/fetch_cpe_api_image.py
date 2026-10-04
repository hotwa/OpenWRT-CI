#!/usr/bin/env python3
"""Stage one pinned official ARM64 OCI image, without build or login secrets."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tarfile
import tempfile
import time
import urllib.request

REPOSITORY = 'eceasy/cli-proxy-api'
DIGEST = 'sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d'
IMAGE = 'docker.io/' + REPOSITORY + '@' + DIGEST
MAX_IMAGE = 400 * 1024 * 1024

def download(url, destination, digest=None, size=None, token=None):
    for attempt in range(4):
        try:
            headers = {'Accept': 'application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'}
            if token:
                headers['Authorization'] = 'Bearer ' + token
            request = urllib.request.Request(url, headers=headers)
            count, sha = 0, hashlib.sha256()
            with urllib.request.urlopen(request, timeout=90) as response, destination.open('wb') as stream:
                while block := response.read(1024 * 1024):
                    count += len(block)
                    if count > MAX_IMAGE or (size is not None and count > size):
                        raise ValueError('image object exceeds declared size')
                    stream.write(block)
                    sha.update(block)
            if digest and sha.hexdigest() != digest.split(':')[1]:
                raise ValueError('image object digest mismatch')
            if size is not None and count != size:
                raise ValueError('image object size mismatch')
            return count
        except Exception:
            destination.unlink(missing_ok=True)
            if attempt == 3:
                raise RuntimeError('pinned image download or verification failed') from None
            time.sleep(2 * (attempt + 1))

def stage(overlay):
    output = overlay / 'usr/share/cpe-api'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cpe-api-oci-') as temporary:
        root = Path(temporary)
        token_path = root / 'token.json'
        download('https://auth.docker.io/token?service=registry.docker.io&scope=repository:' + REPOSITORY + ':pull', token_path)
        token = json.loads(token_path.read_bytes())['token']
        blobs = root / 'blobs/sha256'
        blobs.mkdir(parents=True)
        manifest_path = blobs / DIGEST.split(':')[1]
        registry = 'https://registry-1.docker.io/v2/' + REPOSITORY
        manifest_size = download(registry + '/manifests/' + DIGEST, manifest_path, DIGEST, token=token)
        manifest = json.loads(manifest_path.read_bytes())
        assert manifest['schemaVersion'] == 2
        objects = [manifest['config']] + manifest['layers']
        assert 1 < len(objects) <= 32
        assert sum(item['size'] for item in objects) <= MAX_IMAGE
        for item in objects:
            assert re.fullmatch(r'sha256:[0-9a-f]{64}', item['digest'])
            assert type(item['size']) is int and 0 < item['size'] <= MAX_IMAGE
            download(registry + '/blobs/' + item['digest'], blobs / item['digest'].split(':')[1], item['digest'], item['size'], token)
        config = json.loads((blobs / manifest['config']['digest'].split(':')[1]).read_bytes())
        assert config['architecture'] == 'arm64' and config['os'] == 'linux'
        (root / 'oci-layout').write_text('{"imageLayoutVersion":"1.0.0"}')
        (root / 'index.json').write_text(json.dumps({'schemaVersion': 2, 'manifests': [{
            'mediaType': manifest['mediaType'], 'digest': DIGEST, 'size': manifest_size,
            'annotations': {'io.containerd.image.name': IMAGE, 'org.opencontainers.image.ref.name': 'v8.0.13'},
            'platform': {'architecture': 'arm64', 'os': 'linux'}}]}))
        candidate = output / '.image.tar.new'
        try:
            with tarfile.open(candidate, 'w') as archive:
                for name in ('oci-layout', 'index.json', 'blobs'):
                    archive.add(root / name, arcname=name)
            candidate.chmod(0o644)
            candidate.replace(output / 'cli-proxy-api-v8.0.13-arm64.oci.tar')
        finally:
            candidate.unlink(missing_ok=True)
        (output / 'image.json').write_text(json.dumps({'version': '8.0.13', 'image': IMAGE, 'architecture': 'arm64', 'manifest_digest': DIGEST}) + '\n')
    print('Pinned CLIProxyAPI ARM64 OCI image verified and staged (no credentials)')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: fetch_cpe_api_image.py <overlay>')
    try:
        stage(Path(sys.argv[1]))
    except Exception:
        raise SystemExit('ERROR: pinned CPE API image unavailable or invalid') from None
