import copy
import errno
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime,timezone,timedelta
from pathlib import Path
from unittest.mock import patch
import chromium_15612_postbuild9 as module
from chromium_15612_generated_cache import M156CacheError

class M156Postbuild9Tests(unittest.TestCase):
    def tool_hashes(self):
        directory=Path(module.__file__).parent
        names=module.TOOLS
        return {name:hashlib.sha256((directory/name).read_bytes()).hexdigest() for name in names}

    def state(self):
        end=datetime.now(timezone.utc)-timedelta(seconds=3)
        return {'schemaVersion':1,'status':'native-build-completed-needs-binary-and-runtime-qualification',
                'startedAt':(end-timedelta(seconds=10)).isoformat(),'finishedAt':end.isoformat(),
                'lastResourceSampleAt':(end-timedelta(seconds=1)).isoformat(),
                'contractSHA256':module.FREEZE_SHA256,'argsSHA256':module.ARGS_SHA256,
                'jobs':2,'targets':['chrome','chromedriver'],'sourceInputsFrozen':True,
                'releaseReady':False,'ownerPID':12345,'ninjaPID':12346,'logBytes':7,
                'exitCode':0,'logSHA256':'a'*64}

    def test_terminal_success_requires_absent_actual_process(self):
        with patch.object(module.os,'kill',side_effect=ProcessLookupError(errno.ESRCH,'absent')) as observe:
            module.require_terminal(self.state())
            observe.assert_called_once_with(12346,0)
        # A genuine current PID must not pass even with a synthetic terminal record.
        state=self.state();state['ninjaPID']=os.getpid()
        with self.assertRaisesRegex(M156CacheError,'still exists'):module.require_terminal(state)
        with patch.object(module.os,'kill',side_effect=PermissionError(errno.EPERM,'not observable')):
            with self.assertRaises(M156CacheError):module.require_terminal(self.state())

    def test_running_failed_boolean_wrong_identity_and_extra_fields_rejected(self):
        changes=[{'status':'single-native-build-running'},{'exitCode':1},{'exitCode':False},
                 {'schemaVersion':True},{'jobs':True},{'jobs':4},{'ownerPID':True},{'ninjaPID':1},
                 {'sourceInputsFrozen':1},{'releaseReady':0},{'contractSHA256':'b'*64},
                 {'argsSHA256':'b'*64},{'targets':['chrome']},{'logSHA256':'not-hash'},
                 {'extra':'unreviewed'}]
        for change in changes:
            with self.subTest(change=change),patch.object(module.os,'kill') as observe:
                with self.assertRaises(M156CacheError):module.require_terminal({**self.state(),**change})
                observe.assert_not_called()

    def test_time_order_naive_future_and_unparseable_rejected(self):
        now=datetime.now(timezone.utc)
        for change in ({'startedAt':now.isoformat()},{'finishedAt':(now+timedelta(days=1)).isoformat()},
                       {'lastResourceSampleAt':now.isoformat()},{'finishedAt':'2026-01-01T00:00:00'},
                       {'startedAt':'not-time'}):
            with self.subTest(change=change),self.assertRaises(M156CacheError):
                module.require_terminal({**self.state(),**change})

    def test_authenticate_before_parse_and_no_follow_file(self):
        with tempfile.TemporaryDirectory(prefix='neantik-postbuild-pins-') as temp:
            root=Path(temp);path=root/'owned.json';path.write_text('{"scope":"source-only"}')
            raw=path.read_bytes();h=hashlib.sha256(raw).hexdigest()
            self.assertEqual(module.bound_document(root,path.name,h,64),{'scope':'source-only'})
            with self.assertRaises(M156CacheError):module.bound_document(root,path.name,'b'*64,64)
            with self.assertRaises(M156CacheError):module.bound_document(root,path.name,h,2)
            (root/'link').symlink_to(path)
            with self.assertRaises(OSError):module.bound_document(root,'link',h,64)
            path.write_text('[]')
            with self.assertRaises(M156CacheError):module.bound_document(root,path.name,hashlib.sha256(path.read_bytes()).hexdigest(),64)

    def test_duplicate_json_fields_never_shadow_terminal_claims(self):
        with tempfile.TemporaryDirectory(prefix='neantik-postbuild-duplicates-') as temp:
            root=Path(temp);raw=b'{"exitCode":1,"exitCode":0}'
            (root/'state.json').write_bytes(raw)
            with self.assertRaisesRegex(M156CacheError,'Duplicate'):
                module.bound_document(root,'state.json',hashlib.sha256(raw).hexdigest(),64)

    def test_compact_refuses_unknown_fields_and_partial_inventory(self):
        from test_chromium_15612_generated_cache import snapshot,file
        data=snapshot([file('owned.py')]);data['provenanceLimit']='Source snapshot only'
        with self.assertRaisesRegex(M156CacheError,'coverage'):module.compact(data)
        with self.assertRaisesRegex(M156CacheError,'Unexpected'):
            module.compact({**data,'unreviewed':True})

    def test_running_build_refused_before_log_inventory_or_source(self):
        # Actual scoped invocation against today's running owned state.
        artifacts=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major')
        name='m156-native-build-attempt-9-state.json'
        if not (artifacts/name).is_file():self.skipTest('Owned running-state fixture not present on this machine')
        raw=(artifacts/name).read_bytes();document=json.loads(raw)
        if document.get('status')!='single-native-build-running':self.skipTest('Current build no longer running')
        with patch.object(module,'bound_document',wraps=module.bound_document) as read:
            with self.assertRaisesRegex(M156CacheError,'successful terminal'):
                module.prepare(artifacts=artifacts,source=Path('/unused'),terminal_name=name,
                               terminal_sha256=hashlib.sha256(raw).hexdigest(),final_name='must-not-read',final_sha256='a'*64,
                               python=Path('/unused'),python_sha256='a'*64,tool_hashes=self.tool_hashes(),
                               copy_map_name='must-not-read-copy-map',copy_map_sha256='a'*64)
            self.assertEqual(read.call_count,1)

    def test_independent_tool_pins_reject_changes_and_missing_imported_dependencies(self):
        hashes=self.tool_hashes();module.require_tool_bindings(hashes)
        for name in hashes:
            with self.subTest(name=name),self.assertRaises(M156CacheError):
                module.require_tool_bindings({**hashes,name:'b'*64})
        with self.assertRaises(M156CacheError):module.require_tool_bindings({})
        # Actual source is untouched: simulate bytes changing during proof.
        real=module.read_source_file
        with patch.object(module,'read_source_file',side_effect=lambda root,name,cap: b'changed' if name=='chromium_15612_generated_cache.py' else real(root,name,cap)):
            with self.assertRaises(M156CacheError):module.require_tool_bindings(hashes)

    def test_canonical_digest_matches_independent_serialization(self):
        value=[{'z':7,'a':'é'},['tuple',True]]
        expected=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest()
        self.assertEqual(module.canonical_digest(value),expected)

    def test_attempt4_cannot_qualify_attempt9(self):
        import chromium_15612_postbuild as old
        state=self.state();state['contractSHA256']=old.FREEZE_SHA256
        with self.assertRaises(M156CacheError): module.require_terminal(state)
        import chromium_15612_postbuild5 as predecessor
        state=self.state();state['contractSHA256']=predecessor.FREEZE_SHA256
        with self.assertRaises(M156CacheError): module.require_terminal(state)
        import chromium_15612_postbuild8 as failed_predecessor
        state=self.state();state['contractSHA256']=failed_predecessor.FREEZE_SHA256
        with self.assertRaises(M156CacheError): module.require_terminal(state)
        self.assertEqual(len(module.FREEZE_SHA256),64)
        self.assertEqual(len(module.FULL_SHA256),64)
        self.assertEqual(len(module.COMPACT_SHA256),64)

    def test_copy_map_source_digest_type_namespace_and_duplicate_controls(self):
        from test_chromium_15612_generated_cache import snapshot,file
        full=snapshot([file('tools/owned.py')])
        record={'path':'tools/owned.py','device':1,'inode':17,'links':2,'mode':0o644,
                'uid':os.getuid(),'sizeBytes':1,'sha256':'a'*64,
                'outputAliases':['out/NeAntikM156Qualified20261009/gen/owned.py']}
        document={'schemaVersion':1,'records':[record],'outputFilesInspected':1,
                  'unmatchedCount':0,'runtimeQualified':False,'releaseReady':False}
        self.assertEqual(module.require_copy_map(document,full),{'tools/owned.py':record})
        patches=[{'path':'../owned.py'},{'sha256':'b'*64},{'inode':True},{'links':True},
                 {'uid':True},{'outputAliases':['out/Other/gen/owned.py']},
                 {'outputAliases':['../escape']},{'links':3},
                 {'outputAliases':['out/NeAntikM156Qualified20261009/../escape']},
                 {'unreviewed':True}]
        for change in patches:
            with self.subTest(change=change),self.assertRaises(M156CacheError):
                module.require_copy_map({**document,'records':[{**record,**change}]},full)
        with self.assertRaises(M156CacheError):module.require_copy_map({**document,'records':[record,record]},full)
        for change in ({'schemaVersion':True},{'unmatchedCount':1},{'releaseReady':True},
                       {'runtimeQualified':True},{'unexpected':True}):
            with self.subTest(change=change),self.assertRaises(M156CacheError):
                module.require_copy_map({**document,**change},full)

if __name__=='__main__':unittest.main()
