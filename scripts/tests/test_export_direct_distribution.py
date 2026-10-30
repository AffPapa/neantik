import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('distribution_export', Path(__file__).parents[1] / 'export-direct-distribution.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class DistributionExportTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'source'; source.mkdir()
        for suffix in ('zip', 'dmg'):
            name = f'NeAntik-0.7.20-arm64-notarized.{suffix}'
            payload = source / name; payload.write_bytes(b'qualified fixture ' + suffix.encode()); payload.chmod(0o400)
            sidecar = source / (name + '.sha256')
            sidecar.write_text(hashlib.sha256(payload.read_bytes()).hexdigest() + '  ' + name + '\n'); sidecar.chmod(0o400)
            os.link(payload, root / ('retained-' + suffix))
        return source

    def test_independent_exact_upload_bytes_preserve_retained_transaction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.fixture(root); target = root / 'upload'
            receipt = module.export_distribution(source, target, '0.7.20')
            for item in receipt['files']:
                before = source / item['name']; after = target / item['name']
                self.assertEqual(before.read_bytes(), after.read_bytes())
                self.assertNotEqual(before.stat().st_ino, after.stat().st_ino)
                self.assertEqual(after.stat().st_nlink, 1)
                self.assertEqual(after.stat().st_mode & 0o777, 0o400)
            self.assertEqual((root / 'retained-zip').stat().st_nlink, 2)
            with self.assertRaises(FileExistsError): module.export_distribution(source, target, '0.7.20')

    def test_wrong_hash_and_symlink_never_produce_complete_receipt(self):
        for kind in ('hash', 'symlink'):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); source = self.fixture(root); target = root / 'upload'
                file = source / 'NeAntik-0.7.20-arm64-notarized.zip'
                if kind == 'hash': file.chmod(0o600); file.write_bytes(b'changed'); file.chmod(0o400)
                else: file.unlink(); file.symlink_to(root / 'retained-zip')
                with self.assertRaises((ValueError, OSError)): module.export_distribution(source, target, '0.7.20')
                self.assertFalse((target / 'distribution.json').exists())

    def test_disk_full_retains_sources_and_no_complete_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.fixture(root); target = root / 'upload'
            with patch.object(module.os, 'write', side_effect=OSError(28, 'fixture disk full')):
                with self.assertRaises(OSError): module.export_distribution(source, target, '0.7.20')
            self.assertFalse((target / 'distribution.json').exists())
            self.assertEqual((root / 'retained-zip').read_bytes(), (source / 'NeAntik-0.7.20-arm64-notarized.zip').read_bytes())

    def test_oversized_sidecar_is_refused_before_archive_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.fixture(root); target = root / 'upload'
            sidecar = source / 'NeAntik-0.7.20-arm64-notarized.zip.sha256'
            sidecar.chmod(0o600); sidecar.write_bytes(b'x' * 4097); sidecar.chmod(0o400)
            with self.assertRaises(ValueError): module.export_distribution(source, target, '0.7.20')
            self.assertFalse((target / 'distribution.json').exists())
            self.assertFalse((target / 'NeAntik-0.7.20-arm64-notarized.zip').exists())

    def test_fifo_source_is_refused_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.fixture(root); target = root / 'upload'
            sidecar = source / 'NeAntik-0.7.20-arm64-notarized.zip.sha256'
            sidecar.unlink(); os.mkfifo(sidecar, 0o600)
            with self.assertRaises(ValueError): module.export_distribution(source, target, '0.7.20')
            self.assertFalse((target / 'distribution.json').exists())

    def test_swapped_output_cannot_inherit_source_attestation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.fixture(root); target = root / 'upload'
            original_copy = module.copy_verified
            def swap_after_last_copy(*args, **kwargs):
                result = original_copy(*args, **kwargs)
                if args[1].suffix == '.dmg':
                    output = target / 'NeAntik-0.7.20-arm64-notarized.zip'
                    output.unlink(); output.write_bytes(b'swapped'); output.chmod(0o400)
                return result
            with patch.object(module, 'copy_verified', side_effect=swap_after_last_copy):
                with self.assertRaises(ValueError): module.export_distribution(source, target, '0.7.20')
            self.assertFalse((target / 'distribution.json').exists())
            self.assertEqual((root / 'retained-zip').read_bytes(), (source / 'NeAntik-0.7.20-arm64-notarized.zip').read_bytes())

if __name__ == '__main__': unittest.main()
