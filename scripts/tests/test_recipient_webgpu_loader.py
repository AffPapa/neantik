import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'recipient-webgpu-loader.py'
SPEC = importlib.util.spec_from_file_location('recipient_webgpu_loader', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RecipientLoaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp', prefix='recipient-loader-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = self.root / 'image'
        self.image.write_bytes(b'owned test image')
        self.digest = hashlib.sha256(self.image.read_bytes()).hexdigest()

    def test_exact_sha_and_regular_file_required(self):
        self.assertEqual(MODULE.input_file(self.image, self.digest), self.image)
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            MODULE.input_file(self.image, '0' * 64)
        with self.assertRaisesRegex(ValueError, 'lowercase SHA-256'):
            MODULE.input_file(self.image, self.digest.upper())
        link = self.root / 'link'
        link.symlink_to(self.image)
        with self.assertRaisesRegex(ValueError, 'non-symlink'):
            MODULE.input_file(link, self.digest)

    def test_output_requires_fresh_absolute_non_symlink_parent(self):
        new = self.root / 'new'
        self.assertEqual(MODULE.new_output(new), new)
        new.mkdir()
        with self.assertRaisesRegex(ValueError, 'new absolute'):
            MODULE.new_output(new)
        with self.assertRaisesRegex(ValueError, 'new absolute'):
            MODULE.new_output(Path('relative'))
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'without symlink'):
            MODULE.new_output(alias / 'new-output')

    def test_signing_modes_keep_hardened_runtime_except_adhoc_helper(self):
        path = self.root / 'owned'
        for name in ('WebGPU', 'JavaScriptCore', 'libswiftCompatibilitySpan.dylib'):
            command = MODULE.signing_command('-', name, path)
            self.assertEqual(command[command.index('--options') + 1], 'runtime')
            self.assertIn('--timestamp=none', command)
        helper = MODULE.signing_command('-', 'helper', path)
        self.assertEqual(helper[helper.index('--options') + 1], '0')
        self.assertIn('--timestamp=none', helper)
        for name in ('WebGPU', 'JavaScriptCore', 'libswiftCompatibilitySpan.dylib', 'helper'):
            command = MODULE.signing_command('Developer ID Example', name, path)
            self.assertEqual(command[command.index('--options') + 1], 'runtime')
            self.assertIn('--timestamp', command)
            self.assertNotIn('--timestamp=none', command)
            self.assertNotIn('--entitlements', command)

    def test_missing_marker_refused_before_creating_output_for_both_signing_modes(self):
        build = self.root / 'build'
        gpu = build / 'WebGPU.framework/Versions/A/WebGPU'
        jsc = build / 'JavaScriptCore.framework/Versions/A/JavaScriptCore'
        for path in (gpu, jsc):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self.image.read_bytes())
        for identity in ('-', 'Developer ID Example'):
            output = self.root / ('output-adhoc' if identity == '-' else 'output-dev')
            args = MODULE.parser().parse_args(['--build-root', str(build), '--span-dylib', str(self.image), '--output', str(output), '--identity', identity, '--webgpu-sha256', self.digest, '--jsc-sha256', self.digest, '--span-sha256', self.digest])
            with self.assertRaisesRegex(ValueError, 'marker missing'):
                MODULE.execute(args)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
