import importlib.util
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('font_witness_inputs', ROOT / 'scripts/runtime-platform/verify-font-witness-inputs.py')
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FontWitnessInputsTests(unittest.TestCase):
    def test_actual_inputs_are_source_only(self):
        result = MOD.verify(ROOT / 'runtime/font-policy-v1')
        self.assertEqual(result['status'], 'source-inputs-verified')
        self.assertFalse(result['actualBrowser'])
        self.assertFalse(result['releaseQualified'])

    def test_changed_fixed_font_or_source_or_patch_is_refused(self):
        for changed in ['witness/fonts/owned-canary.ttf', 'witness/font_qa_witness_mac.mm', 'chromium-font-witness.patch']:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as raw:
                root = Path(raw) / 'inputs'
                shutil.copytree(ROOT / 'runtime/font-policy-v1', root)
                path = root / changed
                path.write_bytes(path.read_bytes() + b'changed')
                with self.assertRaises(ValueError): MOD.verify(root)

    def test_missing_asset_and_arbitrary_path_are_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / 'inputs'
            shutil.copytree(ROOT / 'runtime/font-policy-v1', root)
            path = root / 'chromium-font-witness.json'
            manifest = json.loads(path.read_text())
            manifest['fixedAssets'] = manifest['fixedAssets'][:1]
            path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError): MOD.verify(root)
        for path in ['../font.ttf', '/font.ttf', 'a/../font.ttf', './font.ttf']:
            with self.assertRaises(ValueError): MOD.relative(path)

    def test_malformed_font_container_is_refused(self):
        original = (ROOT / 'runtime/font-policy-v1/witness/fonts/owned-canary.ttf').read_bytes()
        for malformed in [b'', b'OTTO' + original[4:], original[:10], original + b'X' * 4096]:
            with self.assertRaises(ValueError): MOD.tiny_sfnt(malformed)
        changed = bytearray(original)
        struct.pack_into('>I', changed, 12 + 8, 0xFFFFFFFF)
        with self.assertRaises(ValueError): MOD.tiny_sfnt(changed)
