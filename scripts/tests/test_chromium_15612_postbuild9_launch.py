"""Owned source-launch controls; these tests never qualify a browser."""
import hashlib
import importlib.util
import json
import marshal
import os
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import chromium_15612_live_source9 as observer
from test_chromium_15612_generated_cache import snapshot, file

LAUNCH=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major/verify-postbuild-full-source-attempt-9.py')


class Attempt9LaunchTests(unittest.TestCase):
    def launcher(self):
        if not LAUNCH.is_file():self.skipTest('Owned deferred attempt9 launcher missing')
        module=types.ModuleType('owned_attempt9_launch');module.__file__=str(LAUNCH)
        exec(compile(LAUNCH.read_bytes(),str(LAUNCH),'exec'),module.__dict__)
        return module

    def test_loader_ignores_valid_wrong_pyc_and_refuses_bad_last_digest_before_first_execution(self):
        launcher=self.launcher();existing=dict(sys.modules)
        with tempfile.TemporaryDirectory(prefix='neantik-loader9-') as temp:
            root=Path(temp).resolve()
            for name in launcher.ORDER:(root/name).write_text('VALUE="source-buffer"\n')
            pins={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in launcher.ORDER}
            last=launcher.ORDER[-1]
            with self.assertRaisesRegex(ValueError,'before load'):
                launcher.load_reviewed_sources(root,{**pins,last:'0'*64})
            for name in launcher.ORDER:self.assertIs(sys.modules.get(name[:-3]),existing.get(name[:-3]))
            source=root/last;info=source.stat();pyc=Path(importlib.util.cache_from_source(str(source)));pyc.parent.mkdir()
            pyc.write_bytes(importlib.util.MAGIC_NUMBER+struct.pack('<III',0,int(info.st_mtime),info.st_size)+
                            marshal.dumps(compile('raise RuntimeError("OWNED_WRONG_PYC")',str(source),'exec')))
            broken=subprocess.run([sys.executable,'-B','-S','-c',
                'import sys;sys.path.insert(0,sys.argv[1]);import chromium_15612_live_source9',str(root)],
                capture_output=True,text=True,timeout=15)
            self.assertNotEqual(broken.returncode,0);self.assertIn('OWNED_WRONG_PYC',broken.stderr)
            try:
                loaded=launcher.load_reviewed_sources(root,pins)
                self.assertEqual(len(loaded),7)
                for module in loaded.values():self.assertEqual(module.VALUE,'source-buffer')
            finally:
                for name in launcher.ORDER:
                    key=name[:-3]
                    if key in existing:sys.modules[key]=existing[key]
                    else:sys.modules.pop(key,None)

    def test_fresh_copy_map_accounts_exact_aliases_and_refuses_external_link(self):
        launcher=self.launcher()
        with tempfile.TemporaryDirectory(prefix='neantik-copy-map9-') as temp:
            root=Path(temp).resolve();source=root/'owned.py';source.write_bytes(b'x=7\n')
            output=root/observer.copies.OUTPUT_PREFIX;output.mkdir(parents=True)
            alias=output/'owned.py';os.link(source,alias);info=source.stat()
            full=snapshot([file('owned.py',hashlib.sha256(source.read_bytes()).hexdigest(),info.st_size)])
            result=launcher.discover_copy_map(root,full,observer)
            self.assertEqual(len(result['records']),1);self.assertEqual(result['outputFilesInspected'],1)
            observer.observe_tree(root,full,result)
            os.link(source,root/'outside-output')
            with self.assertRaises(observer.cache.M156CacheError):launcher.discover_copy_map(root,full,observer)

    def test_bootstrap_leaf_symlink_and_directory_replacement_refused(self):
        launcher=self.launcher()
        with tempfile.TemporaryDirectory(prefix='neantik-bootstrap9-') as temp:
            base=Path(temp).resolve();root=base/'sources';root.mkdir();leaf=root/'owned.py';leaf.write_bytes(b'ok')
            self.assertEqual(launcher.read_bootstrap(root,'owned.py',2),b'ok')
            (root/'link.py').symlink_to(leaf)
            with self.assertRaises(OSError):launcher.read_bootstrap(root,'link.py',100)
            original=os.read;triggered=[]
            def replace(descriptor,count):
                if not triggered:
                    triggered.append(True);root.rename(base/'old');root.mkdir();(root/'owned.py').write_bytes(b'ok')
                return original(descriptor,count)
            with patch.object(launcher.os,'read',side_effect=replace),self.assertRaisesRegex(ValueError,'ancestor replaced'):
                launcher.read_bootstrap(root,'owned.py',100)

    def test_actual_running_build_refused_before_any_new_evidence(self):
        launcher=self.launcher();root=LAUNCH.parent
        state=json.loads((root/'m156-native-build-attempt-9-state.json').read_bytes())
        if state['status']!='single-native-build-running':self.skipTest('Native attempt already terminal')
        config=json.loads((root/launcher.CONFIG_NAME).read_bytes())
        keys=('fullName','compactName','copyMapName','producerReceiptName','deltaReportName','observationName')
        for key in keys:self.assertFalse((root/config[key]).exists())
        result=subprocess.run(['/opt/homebrew/bin/python3.14','-B','-S',str(root/'run-authenticated-postbuild9.py')],capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,1);self.assertEqual(result.stderr,'')
        self.assertEqual(json.loads(result.stdout),{'status':'refused','exceptionType':'M156CacheError',
                                                  'runtimeQualified':False,'releaseReady':False})
        for key in keys:self.assertFalse((root/config[key]).exists())

    def test_replaced_self_read_cannot_claim_executed_buffer_binding(self):
        launcher=self.launcher();raw=LAUNCH.read_bytes()
        with tempfile.TemporaryDirectory(prefix='neantik-launch-self9-') as temp:
            root=Path(temp).resolve();local=root/LAUNCH.name
            local.write_bytes(raw+b'\n# owned replacement after authenticated execution\n')
            (root/launcher.CONFIG_NAME).write_bytes((LAUNCH.parent/launcher.CONFIG_NAME).read_bytes())
            launcher.__file__=str(local)
            launcher.AUTHENTICATED_EXECUTED_BUFFER_SHA256=hashlib.sha256(raw).hexdigest()
            with patch.object(launcher,'load_reviewed_sources') as load:
                with self.assertRaisesRegex(ValueError,'executed launcher buffer'):
                    launcher.execute()
                load.assert_not_called()


if __name__=='__main__':unittest.main()
