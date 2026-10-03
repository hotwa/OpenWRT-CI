#!/usr/bin/env python3
import base64,hashlib,io,json,os,pathlib,shutil,stat,subprocess,tarfile,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
ENCRYPT=ROOT/'Scripts/EncryptFirmwareArtifact.sh';DECRYPT=ROOT/'Scripts/DecryptFirmwareArtifact.sh';FETCH=ROOT/'Scripts/FetchAge.sh'
PIN='cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10'
MOCK_AGE=r'''#!/usr/bin/env python3
import base64,hashlib,pathlib,subprocess,sys
args=sys.argv[1:]
if args==['--version']:print('v1.3.2');sys.exit(0)
def value(k):return args[args.index(k)+1]
try:
 src=pathlib.Path(args[-1]);output=pathlib.Path(value('--output'))
 if '--encrypt' in args:
  key=value('--recipient').split()[1];tag=hashlib.sha256(base64.b64decode(key)).hexdigest().encode()
  output.write_bytes(b'MOCK-AGE\n'+tag+b'\n'+base64.b64encode(src.read_bytes()))
 else:
  key=subprocess.check_output(['ssh-keygen','-y','-f',value('--identity')],stderr=subprocess.DEVNULL).decode().split()[1]
  marker,tag,data=src.read_bytes().split(b'\n',2)
  assert marker==b'MOCK-AGE' and tag==hashlib.sha256(base64.b64decode(key)).hexdigest().encode()
  output.write_bytes(base64.b64decode(data,validate=True))
except Exception:sys.exit(1)
'''
def hash_manifest(directory):
 directory=pathlib.Path(directory)
 data=''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in sorted(directory.iterdir()) if p.name!='SHA256SUMS')
 (directory/'SHA256SUMS').write_text(data)
def call(script,*args,env=None):
 return subprocess.run([str(script),*[str(x) for x in args]],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=90)
class ArtifactTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.shared=tempfile.TemporaryDirectory(prefix='age-artifact-tests-');root=pathlib.Path(cls.shared.name)
  for name in ('identity','wrong'):
   subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-C','artifact-test','-f',str(root/name)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  cls.identity=root/'identity';cls.wrong=root/'wrong';cls.recipient=root/'identity.pub'
  if os.environ.get('AGE_TEST_BINARY'):
   cls.age=pathlib.Path(os.environ['AGE_TEST_BINARY']);cls.real=True
  else:
   cls.age=root/'mock-age';cls.age.write_text(MOCK_AGE);cls.age.chmod(0o755);cls.real=False
   print('NOTE: no AGE_TEST_BINARY; crypto roundtrip skipped, mock-age exercises all pipeline and rejection checks')
 @classmethod
 def tearDownClass(cls):cls.shared.cleanup()
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='age-artifact-case-');self.root=pathlib.Path(self.tmp.name);self.payload=self.root/'payload';self.payload.mkdir(mode=0o700)
  (self.payload/'factory.bin').write_bytes(b'private-image-fixture\0\xff');(self.payload/'sysupgrade.bin').write_bytes(b'private-sysupgrade-fixture');(self.payload/'Config.txt').write_text('private-config-fixture\n');(self.payload/'metadata.json').write_text('{"source":"fixture"}\n');(self.payload/('long-file-'+'x'*112+'.manifest')).write_text('fixture manifest\n');hash_manifest(self.payload)
  self.envelope=self.root/'envelope';self.clear=self.root/'clear'
 def tearDown(self):self.tmp.cleanup()
 def encrypt(self,output=None,env=None):return call(ENCRYPT,self.age,self.payload,self.recipient,output or self.envelope,env=env)
 def decrypt(self,envelope=None,identity=None,output=None):return call(DECRYPT,self.age,envelope or self.envelope,identity or self.identity,output or self.clear)
 def succeeds(self,result):self.assertEqual(result.returncode,0,result.stderr.decode());self.assertEqual(result.stdout,b'')
 def fails(self,result,output):
  self.assertNotEqual(result.returncode,0);self.assertEqual(result.stdout,b'');self.assertFalse(pathlib.Path(output).exists());self.assertNotIn(b'private-image-fixture',result.stderr);self.assertNotIn(b'OPENSSH PRIVATE KEY',result.stderr)
 def test_roundtrip_and_permissions(self):
  original={p.name:p.read_bytes() for p in self.payload.iterdir()};self.succeeds(self.encrypt());self.assertEqual(set(p.name for p in self.envelope.iterdir()),{'firmware.tar.age','SHA256SUMS','ENCRYPTION.json'});self.succeeds(self.decrypt())
  self.assertEqual({p.name:p.read_bytes() for p in self.clear.iterdir()},original);self.assertEqual({p.name:p.read_bytes() for p in self.payload.iterdir()},original)
  for directory in (self.envelope,self.clear):
   self.assertEqual(stat.S_IMODE(directory.stat().st_mode),0o700)
   for p in directory.iterdir():self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600)
 def test_wrong_identity(self):
  self.succeeds(self.encrypt());self.fails(self.decrypt(identity=self.wrong),self.clear)
 def test_ciphertext_tamper(self):
  self.succeeds(self.encrypt());cipher=self.envelope/'firmware.tar.age';cipher.write_bytes(cipher.read_bytes()+b'broken');self.fails(self.decrypt(),self.clear)
 def test_authenticated_ciphertext_tamper_after_outer_hash_is_updated(self):
  self.succeeds(self.encrypt());cipher=self.envelope/'firmware.tar.age';data=bytearray(cipher.read_bytes());data[len(data)//2]^=1;cipher.write_bytes(data);hash_manifest(self.envelope);self.fails(self.decrypt(),self.clear)
 def test_inner_manifest_missing_default_refusal_and_explicit_test_only_generation(self):
  (self.payload/'SHA256SUMS').unlink();self.fails(self.encrypt(),self.envelope)
  env=os.environ.copy();env['CPE5G_ARTIFACT_TEST_ALLOW_MISSING_SUMS']='1';self.succeeds(self.encrypt(env=env));self.assertFalse((self.payload/'SHA256SUMS').exists());self.succeeds(self.decrypt());self.assertTrue((self.clear/'SHA256SUMS').is_file())
 def test_bad_existing_inner_manifest_never_rewritten(self):
  original=(self.payload/'SHA256SUMS').read_bytes();bad=original.replace(b'factory.bin',b'missing.bin');(self.payload/'SHA256SUMS').write_bytes(bad)
  env=os.environ.copy();env['CPE5G_ARTIFACT_TEST_ALLOW_MISSING_SUMS']='1';self.fails(self.encrypt(env=env),self.envelope);self.assertEqual((self.payload/'SHA256SUMS').read_bytes(),bad)
 def test_manifest_missing_extra_duplicate_and_mismatch(self):
  good=(self.payload/'SHA256SUMS').read_text();lines=good.splitlines(keepends=True)
  for index,bad in enumerate([''.join(lines[1:]),good+'0'*64+'  absent.bin\n',good+lines[0],good.replace(lines[0][:64],'0'*64,1)]):
   (self.payload/'SHA256SUMS').write_text(bad);self.fails(self.encrypt(output=self.root/f'bad-{index}'),self.root/f'bad-{index}')
 def test_input_symlink_hardlink_fifo_directory_and_unsafe_names(self):
  for kind in ('symlink','hardlink','fifo','directory','slash','newline'):
   bad=self.payload/('bad\\name' if kind=='slash' else 'bad\nname' if kind=='newline' else 'bad')
   if kind=='symlink':bad.symlink_to(self.payload/'factory.bin')
   elif kind=='hardlink':os.link(self.payload/'factory.bin',bad)
   elif kind=='fifo':os.mkfifo(bad)
   elif kind=='directory':bad.mkdir()
   else:bad.write_text('fixture')
   self.fails(self.encrypt(output=self.root/kind),self.root/kind)
   if bad.is_dir():bad.rmdir()
   else:bad.unlink()
 def test_output_existing_and_symlink_parent_are_refused(self):
  self.envelope.mkdir();(self.envelope/'keep').write_text('existing');result=self.encrypt();self.assertNotEqual(result.returncode,0);self.assertEqual((self.envelope/'keep').read_text(),'existing')
  dangling=self.root/'dangling';dangling.symlink_to(self.root/'absent');self.assertNotEqual(self.encrypt(output=dangling).returncode,0);self.assertTrue(dangling.is_symlink())
  parent=self.root/'alias';parent.symlink_to(self.root,target_is_directory=True);self.fails(self.encrypt(output=parent/'unsafe-output'),self.root/'unsafe-output')
 def test_envelope_shape_and_metadata_checks(self):
  self.succeeds(self.encrypt());original={p.name:p.read_bytes() for p in self.envelope.iterdir()}
  (self.envelope/'extra').write_text('fixture');self.fails(self.decrypt(),self.clear);(self.envelope/'extra').unlink()
  for field in ('age_version','format','recipient_type'):
   metadata=json.loads(original['ENCRYPTION.json']);metadata[field]='wrong';(self.envelope/'ENCRYPTION.json').write_text(json.dumps(metadata));hash_manifest(self.envelope);self.fails(self.decrypt(),self.clear)
  for name,data in original.items():(self.envelope/name).write_bytes(data)
  (self.envelope/'SHA256SUMS').write_text((self.envelope/'SHA256SUMS').read_text().splitlines()[0]+'\n');self.fails(self.decrypt(),self.clear)
 def malicious_envelope(self,kind):
  if not self.envelope.exists():self.succeeds(self.encrypt())
  archive=self.root/'attack.tar'
  with tarfile.open(archive,'w',format=tarfile.PAX_FORMAT) as tar:
   data=b'fixture';normal=tarfile.TarInfo('payload.bin');normal.size=len(data);tar.addfile(normal,io.BytesIO(data))
   name={'parent':'../escape','absolute':'/tmp/age-escape','dot':'./escape','duplicate':'payload.bin'}.get(kind,'bad')
   member=tarfile.TarInfo(name);member.size=0
   if kind=='symlink':member.type=tarfile.SYMTYPE;member.linkname='../escape'
   elif kind=='hardlink':member.type=tarfile.LNKTYPE;member.linkname='payload.bin'
   elif kind=='fifo':member.type=tarfile.FIFOTYPE
   elif kind=='device':member.type=tarfile.CHRTYPE
   elif kind=='directory':member.type=tarfile.DIRTYPE
   elif kind=='sparse':member.type=tarfile.GNUTYPE_SPARSE
   elif kind=='pax':member.pax_headers={'SCHILY.xattr.user.secret':'fixture'}
   elif kind=='missing-sums':pass
   tar.addfile(member,io.BytesIO(b''))
   if kind!='missing-sums':
    digest=hashlib.sha256(data).hexdigest();sums=tarfile.TarInfo('SHA256SUMS');text=(digest+'  payload.bin\n').encode();sums.size=len(text);tar.addfile(sums,io.BytesIO(text))
  cipher=self.envelope/'firmware.tar.age';cipher.unlink()
  key=' '.join(self.recipient.read_text().split()[:2]);result=subprocess.run([str(self.age),'--encrypt','--recipient',key,'--output',str(cipher),str(archive)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30);self.assertEqual(result.returncode,0);hash_manifest(self.envelope)
 def test_malicious_decrypted_tar_is_rejected(self):
  for kind in ('parent','absolute','dot','duplicate','symlink','hardlink','fifo','device','directory','sparse','pax','missing-sums'):
   self.malicious_envelope(kind);output=self.root/f'clear-{kind}';self.fails(self.decrypt(output=output),output)
 def test_decrypt_independently_rejects_bad_inner_checksum_coverage(self):
  self.succeeds(self.encrypt());data=b'plain-fixture';good=hashlib.sha256(data).hexdigest()+'  payload.bin\n'
  for index,manifest in enumerate([good+good,'0'*64+'  payload.bin\n',good+'0'*64+'  absent.bin\n','0'*64+'  absent.bin\n']):
   archive=self.root/f'bad-manifest-{index}.tar'
   with tarfile.open(archive,'w',format=tarfile.GNU_FORMAT) as tar:
    for name,contents in [('payload.bin',data),('SHA256SUMS',manifest.encode())]:
     info=tarfile.TarInfo(name);info.size=len(contents);tar.addfile(info,io.BytesIO(contents))
   cipher=self.envelope/'firmware.tar.age';cipher.unlink();key=' '.join(self.recipient.read_text().split()[:2])
   result=subprocess.run([str(self.age),'--encrypt','--recipient',key,'--output',str(cipher),str(archive)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30);self.assertEqual(result.returncode,0);hash_manifest(self.envelope)
   output=self.root/f'rejected-manifest-{index}';self.fails(self.decrypt(output=output),output)
 def test_only_one_ed25519_recipient(self):
  recipient=self.root/'recipient.pub';recipient.write_text(self.recipient.read_text()*2);result=call(ENCRYPT,self.age,self.payload,recipient,self.envelope);self.fails(result,self.envelope)
  recipient.write_text('ssh-rsa invalid fixture\n');result=call(ENCRYPT,self.age,self.payload,recipient,self.envelope);self.fails(result,self.envelope)
class FetchTests(unittest.TestCase):
 def test_fixed_fetch_pin_and_bad_download_not_published(self):
  with tempfile.TemporaryDirectory(prefix='age-fetch-test-') as directory:
   root=pathlib.Path(directory);bin=root/'bin';bin.mkdir();curl=bin/'curl';curl.write_text("#!/usr/bin/env python3\nimport pathlib,sys\na=sys.argv[1:]\nassert '--proto' in a and '=https' in a\nassert 'https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-linux-amd64.tar.gz' in a\npathlib.Path(a[a.index('--output')+1]).write_bytes(b'untrusted tool')\n");curl.chmod(0o755)
   env=os.environ.copy();env['PATH']=str(bin)+os.pathsep+env['PATH'];output=root/'tool';result=call(FETCH,output,env=env);self.assertNotEqual(result.returncode,0);self.assertFalse(output.exists());self.assertEqual(result.stdout,b'');self.assertIn(b'checksum mismatch',result.stderr)
   text=(ROOT/'Scripts/firmware_artifact_crypto.py').read_text();self.assertIn(PIN,text);self.assertEqual(text.count(PIN),1);self.assertNotIn('/latest/',text)
 def test_verified_official_archive_is_published_without_network(self):
  archive=os.environ.get('AGE_TEST_ARCHIVE')
  if not archive:self.skipTest('AGE_TEST_ARCHIVE not set; verified-release positive fetch is local-only')
  with tempfile.TemporaryDirectory(prefix='age-verified-fetch-') as directory:
   root=pathlib.Path(directory);bin=root/'bin';bin.mkdir();curl=bin/'curl'
   curl.write_text("#!/usr/bin/env python3\nimport os,shutil,sys\na=sys.argv[1:]\nshutil.copyfile(os.environ['AGE_TEST_ARCHIVE'],a[a.index('--output')+1])\n");curl.chmod(0o755)
   env=os.environ.copy();env['PATH']=str(bin)+os.pathsep+env['PATH'];output=root/'tool';result=call(FETCH,output,env=env);self.assertEqual(result.returncode,0,result.stderr.decode());self.assertEqual(result.stdout,b'');self.assertEqual(set(p.name for p in output.iterdir()),{'age'});self.assertEqual(stat.S_IMODE(output.stat().st_mode),0o700)
   version=subprocess.check_output([str(output/'age'),'--version'],stderr=subprocess.DEVNULL).decode().strip();self.assertEqual(version,'v1.3.2')
if __name__=='__main__':unittest.main(verbosity=1)
