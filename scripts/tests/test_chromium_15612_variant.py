"""Identity dispatch controls, not source/build/runtime qualification."""
import copy
import unittest
from pathlib import Path
from unittest.mock import patch
import chromium_15612_variant as subject


class M156VariantTests(unittest.TestCase):
    def lock(self, successor=False):
        prefix = subject.FONT_PREFIX if successor else subject.legacy.PREFIX
        value = {'sourceContract': 'runtime/' + prefix + '-source-contract.json',
                 'sourceProvenance': 'runtime/' + prefix + '-port-candidate.json'}
        if successor:
            value['sourceVariant'] = subject.FONT_VARIANT
        return value

    def test_exact_allowlist_paths_and_legacy_diagnostics(self):
        self.assertEqual(subject.prefix_for({}), subject.legacy.PREFIX)
        for enabled in (False, True):
            lock = self.lock(enabled)
            before = copy.deepcopy(lock)
            self.assertEqual(subject.reviewed_lock_prefix(lock),
                             subject.FONT_PREFIX if enabled else subject.legacy.PREFIX)
            self.assertEqual(lock, before)

    def test_unknown_null_stripped_and_mixed_paths_fail(self):
        for marker in (None, '', 'font-system-v2', {}, [], True, 1):
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                subject.prefix_for({'sourceVariant': marker})
        for key in ('sourceContract', 'sourceProvenance'):
            wrong = self.lock(True)
            wrong.pop('sourceVariant')
            with self.assertRaises(ValueError):
                subject.prefix_for(wrong)
            wrong = self.lock(True)
            wrong[key] = self.lock()[key]
            with self.assertRaises(ValueError):
                subject.prefix_for(wrong)
            missing = self.lock(True)
            missing.pop(key)
            with self.assertRaises(ValueError):
                subject.reviewed_lock_prefix(missing)
        for key in subject._SUCCESSOR_FIELDS:
            with self.assertRaises(ValueError):
                subject.prefix_for({key: '0' * 64})
        for value in (None, [], '156.0.8078.12'):
            with self.assertRaises(ValueError):
                subject.prefix_for(value)

    def test_dispatch_does_not_turn_identity_into_source_approval(self):
        with patch.object(subject.legacy, 'verify_candidate_document', side_effect=ValueError('unqualified')) as check:
            with self.assertRaisesRegex(ValueError, 'unqualified'):
                subject.verify_candidate_document({}, project_root=Path('/owned'))
            check.assert_called_once()
        with patch.object(subject.legacy, 'verify_candidate_lock') as check:
            with self.assertRaisesRegex(ValueError, 'Mismatched'):
                subject.verify_candidate_lock(self.lock(), provenance=self.lock(True), project_root=Path('/owned'))
            check.assert_not_called()


if __name__ == '__main__':
    unittest.main()
