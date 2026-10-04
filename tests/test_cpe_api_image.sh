#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$ROOT" <<'PY'
import hashlib, importlib.util, io, json, pathlib, sys, tarfile, tempfile
from unittest.mock import patch
root=pathlib.Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('fetch',root/'Scripts/fetch_cpe_api_image.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert m.DIGEST=='sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d'
def fixture(architecture='arm64'):
 config=json.dumps({'architecture':architecture,'os':'linux'}).encode(); layer=b'fake immutable layer'
 descriptor=lambda raw,kind:{'mediaType':kind,'digest':'sha256:'+hashlib.sha256(raw).hexdigest(),'size':len(raw)}
 manifest={'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':descriptor(config,'application/vnd.oci.image.config.v1+json'),'layers':[descriptor(layer,'application/vnd.oci.image.layer.v1.tar+gzip')]}
 raw=json.dumps(manifest).encode();digest='sha256:'+hashlib.sha256(raw).hexdigest()
 return digest,{digest:raw,manifest['config']['digest']:config,manifest['layers'][0]['digest']:layer}
def run(arch='arm64',tamper=False):
 digest,objects=fixture(arch)
 def openurl(request,**kwargs):
  url=request if isinstance(request,str) else request.full_url
  if url.startswith('https://auth.docker.io/'):return io.BytesIO(b'{"token":"fixture-only"}')
  raw=objects[url.rsplit('/',1)[1]]
  if tamper and '/blobs/' in url:raw=b'tampered'
  return io.BytesIO(raw)
 with tempfile.TemporaryDirectory() as tmp,patch.object(m,'DIGEST',digest),patch.object(m,'IMAGE','docker.io/eceasy/cli-proxy-api@'+digest),patch.object(m.urllib.request,'urlopen',openurl),patch.object(m.time,'sleep',lambda _:None):
  target=pathlib.Path(tmp)
  if arch!='arm64' or tamper:
   try:m.stage(target)
   except (AssertionError,RuntimeError,ValueError):pass
   else:raise AssertionError('untrusted image accepted')
   assert not (target/'usr/share/cpe-api/cli-proxy-api-v8.0.13-arm64.oci.tar').exists()
  else:
   m.stage(target)
   with tarfile.open(target/'usr/share/cpe-api/cli-proxy-api-v8.0.13-arm64.oci.tar') as archive:
    index=json.load(archive.extractfile('index.json'));assert index['manifests'][0]['digest']==digest
    assert all(not x.name.startswith('/') and '..' not in pathlib.PurePosixPath(x.name).parts for x in archive)
run();run('amd64');run(tamper=True)
print('CPE API image: pinned production digest, OCI generation, architecture and tamper gates passed')
PY
