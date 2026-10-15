import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('generic_inputs', ROOT / 'scripts/runtime-platform/verify-font-generic-inputs.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FontGenericInputTests(unittest.TestCase):
    def test_prepared_source_lineage_is_not_runtime_qualification(self):
        value = module.verify(ROOT / 'runtime/font-policy-v1')
        self.assertEqual(value['commonDefaults'], 7)
        self.assertFalse(value['actualBrowser'])
        self.assertFalse(value['releaseQualified'])

    def test_stale_parent_patch_defaults_and_path_escape_refuse(self):
        with tempfile.TemporaryDirectory(prefix='neantik-generic-inputs.') as tmp:
            d = Path(tmp) / 'inputs'
            d.mkdir()
            for name in ['chromium-font-generic-defaults.json', 'chromium-font-generic-defaults.patch', 'chromium-font-cleanup-cstring.json']:
                shutil.copy2(ROOT / 'runtime/font-policy-v1' / name, d / name)
            f = d / 'chromium-font-generic-defaults.json'
            original = json.loads(f.read_text())
            mutations = [lambda m: m.update(parentManifestSHA256='0' * 64),
                         lambda m: m.update(patchSHA256='0' * 64),
                         lambda m: m['defaults'].update(Fixed='Times'),
                         lambda m: m['files'][0].update(path='../escape'),
                         lambda m: m.update(releaseReady=True)]
            for mutate in mutations:
                m = json.loads(json.dumps(original))
                mutate(m)
                f.write_text(json.dumps(m))
                with self.assertRaises(ValueError):
                    module.verify(d)


if __name__ == '__main__':
    unittest.main()
