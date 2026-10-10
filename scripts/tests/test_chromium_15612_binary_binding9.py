"""Synthetic byte/metadata controls; not evidence of a native build or launch."""
import hashlib
import os
import plistlib
import struct
import tempfile
import unittest
from datetime import datetime,timezone,timedelta
from pathlib import Path
from unittest.mock import patch
import chromium_15612_binary_binding9 as binding
from chromium_15612_postbuild9 import FREEZE_SHA256


class BinaryBinding9Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='neantik-binding-',dir='/private/tmp')
        self.root=Path(self.temp.name);self.app=self.root/'NeAntik Browser.app'
        self.info=self.app/'Contents/Info.plist';self.exe=self.app/'Contents/MacOS/NeAntik Browser'
        self.framework=self.app/('Contents/Frameworks/NeAntik Browser Framework.framework/Versions/'+binding.VERSION+'/NeAntik Browser Framework')
        self.args=self.root/'args.gn';self.args.write_bytes(b'synthetic owned args\n')
        for file in [self.info,self.exe,self.framework]:file.parent.mkdir(parents=True,exist_ok=True)
        self.info.write_bytes(plistlib.dumps({'CFBundleExecutable':'NeAntik Browser','CFBundleShortVersionString':binding.VERSION}))
        for file,kind in [(self.exe,2),(self.framework,6)]:
            file.write_bytes(struct.pack('<8I',0xfeedfacf,0x0100000c,0,kind,1,8,0,0)+b'OWNEDMCK');file.chmod(0o755)
        now=datetime.now(timezone.utc)
        self.terminal={'schemaVersion':1,'status':'native-build-completed-needs-binary-and-runtime-qualification',
          'startedAt':(now-timedelta(seconds=3)).isoformat(),'finishedAt':(now-timedelta(seconds=1)).isoformat(),
          'lastResourceSampleAt':(now-timedelta(seconds=2)).isoformat(),'contractSHA256':FREEZE_SHA256,
          'argsSHA256':binding.ARGS_SHA256,'jobs':2,'targets':['chrome','chromedriver'],'sourceInputsFrozen':True,
          'releaseReady':False,'ownerPID':os.getpid(),'ninjaPID':2147483646,'logBytes':1,'logSHA256':'a'*64,'exitCode':0}
    def tearDown(self):self.temp.cleanup()
    def observe(self):
        # Synthetic argument bytes are explicitly substituted only in unit tests.
        with patch.object(binding,'ARGS_SHA256',hashlib.sha256(self.args.read_bytes()).hexdigest()):
            return binding.observe_unsigned_candidate(self.app,self.args,self.terminal,'b'*64)
    def test_streamed_byte_binding_is_not_runtime_qualification(self):
        r=self.observe();self.assertEqual(r['binaryBinding']['candidateExecutableSHA256'],hashlib.sha256(self.exe.read_bytes()).hexdigest())
        for flag in ['sourceManifestAuthenticated','nativeOutputLoadabilityVerified','developerIDVerified','runtimeQualified','releaseReady']:self.assertIs(r[flag],False)
    def test_running_build_refused_before_any_app_access(self):
        self.terminal['status']='single-native-build-running'
        with patch.object(binding,'observe_regular',side_effect=AssertionError('Must not read app')) as reader:
            with self.assertRaises(ValueError):self.observe()
            reader.assert_not_called()
    def test_wrong_version_architecture_kind_or_truncation_refused(self):
        original=self.exe.read_bytes()
        for data in [original[:16],original.replace(struct.pack('<I',0x0100000c),struct.pack('<I',0x01000007),1),original[:12]+struct.pack('<I',6)+original[16:]]:
            self.exe.write_bytes(data)
            with self.assertRaises(ValueError):self.observe()
        self.exe.write_bytes(original);self.info.write_bytes(plistlib.dumps({'CFBundleExecutable':'NeAntik Browser','CFBundleShortVersionString':'155.0.8059.40'}))
        with self.assertRaises(ValueError):self.observe()
    def test_symlink_hardlink_and_missing_execute_mode_refused(self):
        self.exe.chmod(0o644)
        with self.assertRaises(ValueError):self.observe()
        self.exe.chmod(0o755);alias=self.root/'hardlink';os.link(self.exe,alias)
        with self.assertRaises(ValueError):self.observe()
        alias.unlink();saved=self.root/'saved';self.exe.rename(saved);self.exe.symlink_to(saved)
        with self.assertRaises((ValueError,OSError)):self.observe()
    def test_args_and_manifest_digest_refused(self):
        with self.assertRaises(ValueError):binding.observe_unsigned_candidate(self.app,self.args,self.terminal,'b'*64)
        with self.assertRaises(ValueError):binding.observe_unsigned_candidate(self.app,self.args,self.terminal,'not-a-digest')
    def test_source_ancestor_alias_refused(self):
        alias=self.root/'aliased-app';alias.symlink_to(self.app,target_is_directory=True)
        with self.assertRaises((OSError,ValueError)):
            binding.observe_unsigned_candidate(alias,self.args,self.terminal,'b'*64)
    def test_noncanonical_root_refused(self):
        with self.assertRaises(ValueError):
            binding.observe_regular(self.root/'child/..','args.gn',1024)

    def test_predecessor8_terminal_refused_before_any_app_access(self):
        from chromium_15612_postbuild8 import FREEZE_SHA256 as previous
        self.terminal['contractSHA256']=previous
        with patch.object(binding,'observe_regular',side_effect=AssertionError('Must not read app')) as reader:
            with self.assertRaises(ValueError):self.observe()
            reader.assert_not_called()
    def test_actual_running9_refused_before_any_app_access(self):
        import json
        path=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major/m156-native-build-attempt-9-state.json')
        actual=json.loads(path.read_bytes())
        if actual['status']!='single-native-build-running':self.skipTest('Owned native9 already terminal')
        with patch.object(binding,'observe_regular',side_effect=AssertionError('Must not read app')) as reader:
            with self.assertRaises(ValueError):binding.observe_unsigned_candidate(self.app,self.args,actual,'b'*64)
            reader.assert_not_called()

if __name__=='__main__':unittest.main()
