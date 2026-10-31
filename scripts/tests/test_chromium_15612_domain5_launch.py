"""Exact attempt5 launch controls; not actual native cache/runtime proof."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major')
NAME='verify-domain-cache-replay-attempt-5.py'


class Domain5LaunchTests(unittest.TestCase):
    def load(self,path):
        if not path.is_file():self.skipTest('Owned deferred domain stage missing')
        raw=path.read_bytes();module=types.ModuleType('owned_domain_stage')
        module.__file__=str(path);module.AUTHENTICATED_EXECUTED_BUFFER_SHA256=hashlib.sha256(raw).hexdigest()
        exec(compile(raw,str(path),'exec'),module.__dict__)
        return raw,module

    def test_three_initial_read_bounds_have_actual_previous_failure_and_corrected_refusal(self):
        old_path=ROOT/'verify-domain-cache-replay-attempt-5-initial-reviewed.py'
        new_path=ROOT/NAME
        for surface in ('code','config','loader'):
            for corrected,path in ((False,old_path),(True,new_path)):
                with self.subTest(surface=surface,corrected=corrected),tempfile.TemporaryDirectory(prefix='neantik-domain-bound5-') as temp:
                    root=Path(temp).resolve();raw,module=self.load(path);module.__file__=str(root/NAME)
                    (root/NAME).write_bytes(raw)
                    (root/module.CONFIG_NAME).write_bytes((ROOT/module.CONFIG_NAME).read_bytes())
                    loader=root/'verify-postbuild-full-source-attempt-5.py'
                    loader.write_bytes((ROOT/loader.name).read_bytes())
                    target={'code':root/NAME,'config':root/module.CONFIG_NAME,'loader':loader}[surface]
                    size=64*1024+1 if surface=='config' else 1024*1024+1
                    target.write_bytes(b'x'*size)
                    original=Path.read_bytes;consumed=[]
                    def read_bytes(path):
                        result=original(path)
                        if path==target:consumed.append(len(result))
                        return result
                    with patch.object(Path,'read_bytes',read_bytes),self.assertRaises(ValueError):
                        module.execute()
                    self.assertEqual(consumed,[] if corrected else [size])

    def test_config_symlink_refused_before_loading_helpers(self):
        raw,module=self.load(ROOT/NAME)
        with tempfile.TemporaryDirectory(prefix='neantik-domain-links5-') as temp:
            root=Path(temp).resolve();module.__file__=str(root/NAME);(root/NAME).write_bytes(raw)
            target=root/'config-target';target.write_bytes((ROOT/module.CONFIG_NAME).read_bytes())
            (root/module.CONFIG_NAME).symlink_to(target)
            with self.assertRaises(OSError):module.execute()

    def test_actual_running_build_refused_without_native_cache_report(self):
        self.load(ROOT/NAME)
        state=json.loads((ROOT/'m156-native-build-attempt-5-state.json').read_bytes())
        if state['status']!='single-native-build-running':self.skipTest('Owned native attempt terminal')
        config=json.loads((ROOT/'domain-cache-replay-attempt-5-launch-v2.json').read_bytes())
        self.assertFalse((ROOT/config['actualReportName']).exists())
        result=subprocess.run(['/opt/homebrew/bin/python3.14','-B','-S',str(ROOT/'run-authenticated-domain-replay5-v3.py')],
                              capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,1);self.assertEqual(result.stderr,'')
        self.assertEqual(json.loads(result.stdout),{'status':'refused','exceptionType':'M156CacheError',
                                                  'runtimeQualified':False,'releaseReady':False})
        self.assertFalse((ROOT/config['actualReportName']).exists())


if __name__=='__main__':unittest.main()
