import copy
import hashlib
import unittest

import chromium_15612_correction_lineage as module
from chromium_15612_generated_cache import M156CacheError

H = 'a' * 64
OTHER = 'b' * 64


class M156CorrectionLineageTests(unittest.TestCase):
    def test_ordered_changes_and_explicit_new_file(self):
        current = {'owned.cc': H, 'new.h': None}
        self.assertEqual(module.advance(current, {'owned.cc': H, 'new.h': None},
                                        {'owned.cc': OTHER, 'new.h': H}), 0)
        self.assertEqual(current, {'owned.cc': OTHER, 'new.h': H})
        self.assertEqual(module.advance(current, {'owned.cc': OTHER}, {'owned.cc': H}), 0)

    def test_stale_and_null_preimages_never_silently_override_known_state(self):
        for pre in ({'owned.cc': OTHER}, {'owned.cc': None}):
            current = {'owned.cc': H}
            with self.subTest(pre=pre), self.assertRaisesRegex(M156CacheError, 'Broken'):
                module.advance(current, pre, {'owned.cc': OTHER}, unknown_allowed=True)
            self.assertEqual(current, {'owned.cc': H})

    def test_missing_domain_stage_is_caught_by_next_patch(self):
        # Exact pattern observed for compiler/BUILD.gn: domain substitution
        # supplies the ThinLTO patch preimage, not the preceding source replay.
        current = {'build/config/compiler/BUILD.gn': H}
        with self.assertRaisesRegex(M156CacheError, 'Broken'):
            module.advance(current, {'build/config/compiler/BUILD.gn': OTHER},
                           {'build/config/compiler/BUILD.gn': 'c'*64})
        module.advance(current, {'build/config/compiler/BUILD.gn': H},
                       {'build/config/compiler/BUILD.gn': OTHER})
        module.advance(current, {'build/config/compiler/BUILD.gn': OTHER},
                       {'build/config/compiler/BUILD.gn': 'c'*64})
        self.assertEqual(current['build/config/compiler/BUILD.gn'], 'c'*64)

    def test_unknown_origins_require_explicit_partial_scope_and_are_counted(self):
        current = {'known.cc': H}
        with self.assertRaisesRegex(M156CacheError, 'Unanchored'):
            module.advance(current, {'unobserved.cc': H}, {'unobserved.cc': OTHER})
        self.assertNotIn('unobserved.cc', current)
        self.assertEqual(module.advance(current, {'unobserved.cc': H}, {'unobserved.cc': OTHER},
                                        unknown_allowed=True), 1)
        self.assertEqual(current['unobserved.cc'], OTHER)

    def test_unknown_paths_types_digest_and_mismatched_coverage_refused(self):
        for pre, post in (({'../outside': H}, {'../outside': OTHER}),
                          ({'safe': 'not-sha'}, {'safe': OTHER}),
                          ({'safe': True}, {'safe': OTHER}),
                          ({'safe': H}, {'different': OTHER}), ({}, {})):
            with self.subTest(pre=pre), self.assertRaises(M156CacheError):
                module.advance({'safe': H}, pre, post)

    def test_unified_patch_target_coverage_preserves_explicit_new_file(self):
        raw = b'--- a/owned.cc\n+++ b/owned.cc\n@@ -1 +1 @@\n-old\n+new\n--- /dev/null\n+++ b/new.h\n@@ -0,0 +1 @@\n+new\n'
        self.assertEqual(module.patch_paths(raw), {'owned.cc', 'new.h'})
        # Target coverage is deliberately not a claim that hunks applied.

    def test_patch_traversal_duplicate_incomplete_delete_rename_and_unknown_prefix_refused(self):
        broken = [b'+++ b/owned.cc\n', b'--- a/owned.cc\n',
                  b'--- a/owned.cc\n+++ b/../outside\n',
                  b'--- a/owned.cc\n+++ /dev/null\n',
                  b'--- a/owned.cc\n+++ b/renamed.cc\n',
                  b'--- owned.cc\n+++ b/owned.cc\n',
                  b'--- a/owned.cc\n+++ b/owned.cc\n--- a/owned.cc\n+++ b/owned.cc\n']
        for raw in broken:
            with self.subTest(raw=raw), self.assertRaises(M156CacheError): module.patch_paths(raw)


if __name__ == '__main__': unittest.main()
