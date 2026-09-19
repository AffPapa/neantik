import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runtime_contract_selection import CONTRACT_NAMES, select_contract


class ContractSelectionTests(unittest.TestCase):
    def test_each_version_selected_by_hash_not_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in CONTRACT_NAMES:
                (root / name).write_text(name)
            for name in CONTRACT_NAMES:
                digest = hashlib.sha256(name.encode()).hexdigest()
                self.assertEqual(select_contract(root, digest), root / name)

    def test_missing_mutated_duplicate_and_symlink_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            digest = hashlib.sha256(b'reviewed').hexdigest()
            with self.assertRaises(ValueError):
                select_contract(root, digest)
            first, second = (root / n for n in CONTRACT_NAMES)
            first.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                select_contract(root, digest)
            first.write_bytes(b'reviewed')
            second.write_bytes(b'reviewed')
            with self.assertRaises(ValueError):
                select_contract(root, digest)
            second.unlink()
            second.symlink_to(first)
            with self.assertRaises(ValueError):
                select_contract(root, digest)

    def test_invalid_digest_and_directory_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for value in ('', '0' * 63, None, '../contract'):
                with self.assertRaises(ValueError):
                    select_contract(root, value)
            with self.assertRaises(ValueError):
                select_contract(root / 'absent', '0' * 64)
