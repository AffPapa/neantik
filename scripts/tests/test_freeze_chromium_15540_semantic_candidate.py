"""Fault after the first publication must roll back only owned evidence."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('semantic_freezer', SCRIPTS / 'freeze-chromium-15540-semantic-candidate.py')
freezer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(freezer)
import chromium_15540_generated_cache as cache


class SemanticCandidateTransactionTests(unittest.TestCase):
    def test_derivation_timeout_after_snapshot_rolls_back_without_touching_prior_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / 'runtime'
            runtime.mkdir()
            prefix = 'chromium-15540-semantic-v4'
            source = root / 'source'
            source.mkdir()
            args = source / 'args.gn'
            args.write_text('synthetic build arguments')
            snapshot = {'argsGN': {'relativePath': 'args.gn'}, 'synthetic': True}
            before = runtime / (prefix + '-prebuild-source-snapshot.json')
            before.write_text(json.dumps(snapshot, sort_keys=True, indent=2) + '\n')
            bindings = {key: 'a' * 64 for key in freezer.semantic.BINDINGS}
            bindings['semanticCorrectionSet'] = 'canvas-audio-webgl-native-webrtc-layout-text-v4'
            bindings['sourceInputSnapshotSHA256'] = freezer.base.sha256_file(before)
            bindings['generatedBuildCacheEvidenceSHA256'] = 'b' * 64
            receipt = {**bindings}
            manifest = {**bindings}
            originals = {name: (runtime / name) for name in (prefix + '-corrections-receipt.json', prefix + '-corrections-manifest.json', 'prior-candidate.json')}
            for file in originals.values():
                file.write_bytes(b'preserved previous input')
            original_hash = freezer.base.sha256_file
            digests = iter([cache.SOURCE_HASH, cache.CACHE_HASH])
            def cache_hash(path):
                return next(digests) if str(path).endswith((cache.SOURCE, cache.CACHE)) else original_hash(path)
            def safe(root_path, relative):
                return root_path / relative
            def document(path):
                return receipt if path.name.endswith('-corrections-receipt.json') else manifest
            with patch.object(freezer, 'PROJECT', root), \
                 patch.object(freezer.base, 'verify_contract', return_value=({'buildArgsSHA256': original_hash(args)}, {})), \
                 patch.object(freezer.base, 'safe_relative_regular', side_effect=safe), \
                 patch.object(freezer.base, 'sha256_file', side_effect=cache_hash), \
                 patch.object(freezer.corrections, 'object_at', side_effect=document), \
                 patch.object(freezer.corrections, 'verify_live_postimages'), \
                 patch.object(freezer.semantic, 'verify_receipt'), \
                 patch.object(freezer.semantic, 'verify_delta'), \
                 patch.object(freezer, 'build_snapshot', return_value={}), \
                 patch.object(cache.subprocess, 'run', side_effect=subprocess.TimeoutExpired('python', 15)), \
                 patch.object(sys, 'argv', ['freeze', str(source), str(args), str(root / 'unsigned.app'), '--variant', bindings['semanticCorrectionSet']]):
                self.assertEqual(freezer.main(), 1)
            self.assertFalse((runtime / (prefix + '-source-snapshot.json')).exists())
            self.assertEqual(set(runtime.iterdir()), {before, *originals.values()})
            for file in originals.values():
                self.assertEqual(file.read_bytes(), b'preserved previous input')


if __name__ == '__main__':
    unittest.main()
