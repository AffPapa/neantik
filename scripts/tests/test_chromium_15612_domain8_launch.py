"""Attempt8 replay source-buffer controls; no actual native cache qualification."""
from pathlib import Path
import hashlib,json,subprocess,tempfile,types,unittest
from unittest.mock import patch
ROOT=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major')
NAME='verify-domain-cache-replay-attempt-8.py'
class Domain8LaunchTests(unittest.TestCase):
 def load(self):
  raw=(ROOT/NAME).read_bytes();m=types.ModuleType('owned_domain8');m.__file__=str(ROOT/NAME);m.AUTHENTICATED_EXECUTED_BUFFER_SHA256=hashlib.sha256(raw).hexdigest();exec(compile(raw,str(ROOT/NAME),'exec'),m.__dict__);return raw,m
 def test_code_config_loader_bounds_reject_without_unbounded_read(self):
  for surface in ('code','config','loader'):
   with self.subTest(surface=surface),tempfile.TemporaryDirectory(prefix='neantik-domain8-bounds-') as tmp:
    root=Path(tmp).resolve();raw,m=self.load();m.__file__=str(root/NAME);(root/NAME).write_bytes(raw);(root/m.CONFIG_NAME).write_bytes((ROOT/m.CONFIG_NAME).read_bytes());loader=root/'verify-postbuild-full-source-attempt-8.py';loader.write_bytes((ROOT/loader.name).read_bytes());target={'code':root/NAME,'config':root/m.CONFIG_NAME,'loader':loader}[surface];target.write_bytes(b'x'*(64*1024+1 if surface=='config' else 1024*1024+1))
    original=Path.read_bytes;consumed=[]
    def read(path):
     result=original(path)
     if path==target:consumed.append(len(result))
     return result
    with patch.object(Path,'read_bytes',read),self.assertRaises(ValueError):m.execute()
    self.assertEqual(consumed,[])
 def test_config_symlink_rejected_before_helpers(self):
  raw,m=self.load()
  with tempfile.TemporaryDirectory(prefix='neantik-domain8-links-') as tmp:
   root=Path(tmp).resolve();m.__file__=str(root/NAME);(root/NAME).write_bytes(raw);target=root/'target';target.write_bytes((ROOT/m.CONFIG_NAME).read_bytes());(root/m.CONFIG_NAME).symlink_to(target)
   with self.assertRaises(OSError):m.execute()
 def test_current_running_attempt_refused_without_actual_archive_report(self):
  state=json.loads((ROOT/'m156-native-build-attempt-8-state.json').read_bytes())
  if state['status']!='single-native-build-running':self.skipTest('Native attempt is terminal')
  raw,m=self.load();config=json.loads((ROOT/m.CONFIG_NAME).read_bytes());self.assertFalse((ROOT/config['actualReportName']).exists())
  result=subprocess.run(['/opt/homebrew/bin/python3.14','-B','-S',str(ROOT/'run-authenticated-domain-replay8.py')],capture_output=True,text=True,timeout=15)
  self.assertEqual(result.returncode,1);self.assertEqual(result.stderr,'');self.assertEqual(json.loads(result.stdout),{'status':'refused','exceptionType':'M156CacheError','runtimeQualified':False,'releaseReady':False});self.assertFalse((ROOT/config['actualReportName']).exists())
if __name__=='__main__':unittest.main()
