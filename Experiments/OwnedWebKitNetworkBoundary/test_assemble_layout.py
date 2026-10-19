"""Filesystem controls; not signature or native WebKit evidence."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('assembly', Path(__file__).with_name('assemble_layout.py'))
assembly = importlib.util.module_from_spec(spec); spec.loader.exec_module(assembly)


def copy(source, destination):
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination)


class AssemblyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'; self.source.mkdir()
        framework = self.source / 'WebKit.framework/Versions/A'
        (framework / 'Frameworks').mkdir(parents=True)
        (framework / 'XPCServices').mkdir()
        (self.source / 'libWebKitSwift.dylib').write_bytes(b'library')
        (framework / 'Frameworks/libWebKitSwift.dylib').symlink_to('../../../../libWebKitSwift.dylib')
        for name in ('GPU', 'Model', 'Networking', 'WebContent.CaptivePortal',
                     'WebContent.Development', 'WebContent.EnhancedSecurity', 'WebContent'):
            name = 'com.apple.WebKit.' + name + '.xpc'
            (self.source / name).mkdir()
            (self.source / name / 'executable').write_bytes(b'owned-fixture')
            (framework / 'XPCServices' / name).symlink_to('../../../../' + name)
        self.output = self.root / 'output'

    def test_materializes_only_copy_and_preserves_source(self):
        result = assembly.assemble(self.source, self.output, copy)
        self.assertEqual(len(result['materialized']), 8)
        self.assertTrue((self.source / result['materialized'][0]['path']).is_symlink())
        self.assertFalse((self.output / result['materialized'][0]['path']).is_symlink())
        self.assertEqual((self.output / result['materialized'][0]['path']).read_bytes(), b'library')

    def test_existing_output_is_never_replaced(self):
        self.output.mkdir()
        with self.assertRaises(ValueError): assembly.assemble(self.source, self.output, copy)

    def test_escape_refused_before_copy(self):
        (self.source / 'escape').symlink_to(self.root)
        with self.assertRaises(ValueError): assembly.assemble(self.source, self.output, copy)
        self.assertFalse(self.output.exists())

    def test_unexpected_layout_refused_before_copy(self):
        path = self.source / 'WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib'
        path.unlink(); path.write_bytes(b'not-the-known-layout')
        with self.assertRaises(ValueError): assembly.assemble(self.source, self.output, copy)
        self.assertFalse(self.output.exists())

    def test_known_empty_framework_alias_is_completed_only_in_copy(self):
        root = self.source / 'WebCore.framework'
        (root / 'Versions/A').mkdir(parents=True)
        (root / 'Versions/Current').symlink_to('A')
        (root / 'Frameworks').symlink_to('Versions/Current/Frameworks')
        assembly.assemble(self.source, self.output, copy)
        self.assertFalse((root / 'Frameworks').exists())
        self.assertTrue((self.output / 'WebCore.framework/Frameworks').is_dir())

    def test_unknown_dangling_link_is_refused(self):
        (self.source / 'missing').symlink_to('absent')
        with self.assertRaises(ValueError): assembly.assemble(self.source, self.output, copy)
        self.assertFalse(self.output.exists())

    def test_omits_sdk_stubs_without_changing_source(self):
        stub = self.source / 'WebKit.framework/Versions/A/WebKit.tbd'
        stub.write_bytes(b'sdk-only')
        link = self.source / 'WebKit.framework/WebKit.tbd'
        link.symlink_to('Versions/A/WebKit.tbd')
        result = assembly.assemble(self.source, self.output, copy)
        self.assertEqual(len(result['omittedSDKStubs']), 2)
        self.assertTrue(stub.exists()); self.assertTrue(link.is_symlink())
        self.assertFalse((self.output / stub.relative_to(self.source)).exists())


if __name__ == '__main__': unittest.main()
