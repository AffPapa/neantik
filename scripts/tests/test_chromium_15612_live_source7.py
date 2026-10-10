import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import chromium_15612_live_source7 as module
from chromium_15612_generated_cache import M156CacheError
from test_chromium_15612_generated_cache import snapshot,file


class M156LiveSource7Tests(unittest.TestCase):
    def tools(self):
        root=Path(module.__file__).parent
        return {name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in module.TOOLS}

    def fixture(self,root):
        package=root/'package';package.mkdir();source=package/'owned.py';source.write_bytes(b'value=7\n')
        output=root/module.copies.OUTPUT_PREFIX/'package';output.mkdir(parents=True)
        alias=output/'owned.py';os.link(source,alias);info=source.stat()
        digest=hashlib.sha256(source.read_bytes()).hexdigest()
        full=snapshot([file('package/owned.py',digest,info.st_size)])
        record={'path':'package/owned.py','device':info.st_dev,'inode':info.st_ino,'links':2,
                'mode':0o644,'uid':os.getuid(),'sizeBytes':info.st_size,'sha256':digest,
                'outputAliases':[alias.relative_to(root).as_posix()]}
        document={'schemaVersion':1,'records':[record],'outputFilesInspected':1,'unmatchedCount':0,
                  'runtimeQualified':False,'releaseReady':False}
        return source,output,info,full,document

    def test_mapped_copy_passes_complete_coverage_unknown_link_and_extra_leaf_refused(self):
        with tempfile.TemporaryDirectory(prefix='neantik-fullcopy-') as temp:
            root=Path(temp).resolve();source,output,info,full,document=self.fixture(root)
            result=module.observe_tree(root,full,document)
            self.assertEqual(result['sourceFileCount'],1)
            self.assertEqual(result['explicitCopyGroupsObserved'],1)
            self.assertTrue(result['exactCoverageVerified'])
            empty={**document,'records':[]}
            with self.assertRaises(M156CacheError):module.observe_tree(root,full,empty)
            (root/'unexpected').write_bytes(b'new')
            with self.assertRaises(M156CacheError):module.observe_tree(root,full,document)

    def test_actual_nested_source_and_output_replacement_refused(self):
        for side in ('source','output'):
            with self.subTest(side=side),tempfile.TemporaryDirectory(prefix='neantik-fullcopy-race-') as temp:
                root=Path(temp).resolve();source,output,info,full,document=self.fixture(root)
                read=os.read;triggered=[]
                def replace(descriptor,count):
                    if not triggered and os.fstat(descriptor).st_ino==info.st_ino:
                        triggered.append(True);directory=source.parent if side=='source' else output
                        directory.rename(directory.with_name('package-old'));directory.mkdir()
                        (directory/'owned.py').write_bytes(b'different\n')
                    return read(descriptor,count)
                with patch.object(module.copies.os,'read',side_effect=replace),self.assertRaises(M156CacheError):
                    module.observe_tree(root,full,document)
                self.assertTrue(triggered)

    def test_dependency_closure_and_source_changes_refused(self):
        pins=self.tools();module.require_tools(pins)
        for name in pins:
            with self.subTest(name=name),self.assertRaises(M156CacheError):
                module.require_tools({**pins,name:'a'*64})
            missing=dict(pins);missing.pop(name)
            with self.subTest(missing=name),self.assertRaises(M156CacheError):module.require_tools(missing)

    def test_real_running_attempt7_refused_before_inventory_source_or_alias_reads(self):
        artifacts=(Path(__file__).resolve().parents[3] / 'artifacts/neantik/looper-goals/20261008-fury-major')
        terminal=artifacts/'m156-native-build-attempt-7-state.json'
        if not terminal.exists():self.skipTest('Owned native attempt7 not available')
        raw=terminal.read_bytes()
        if json.loads(raw)['status']!='single-native-build-running':self.skipTest('Native attempt no longer running')
        with patch.object(module.postbuild,'bound_document',wraps=module.postbuild.bound_document) as reads:
            with self.assertRaises(M156CacheError):
                module.prepare(artifacts=artifacts,source=Path('/unused'),terminal_name=terminal.name,
                    terminal_sha256=hashlib.sha256(raw).hexdigest(),final_name='must-not-read',final_sha256='a'*64,
                    compact_name='must-not-read',compact_sha256='a'*64,
                    copy_map_name='must-not-read',copy_map_sha256='a'*64,tool_hashes=self.tools())
            self.assertEqual(reads.call_count,1)

if __name__=='__main__':unittest.main()
