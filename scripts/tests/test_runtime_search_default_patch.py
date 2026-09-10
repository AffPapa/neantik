import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeSearchDefaultPatchTests(unittest.TestCase):
    def setUp(self):
        manifest = json.loads((ROOT / 'runtime/nevision-patches/series.json').read_text())
        self.group = next(g for g in manifest['patchGroups'] if g['id'] == 'submitted-query-search-default')
        self.patch = ROOT / 'runtime/nevision-patches' / self.group['patchFile']
        self.text = self.patch.read_text()

    def test_reviewed_patch_is_locked_and_only_changes_fallback_and_tests(self):
        self.assertEqual(hashlib.sha256(self.patch.read_bytes()).hexdigest(), self.group['patchSHA256'])
        expected = {
            'components/search_engines/template_url_prepopulate_data_resolver.cc',
            'components/search_engines/default_search_manager_unittest.cc',
            'chrome/browser/history/top_sites_factory.cc',
            'chrome/browser/ntp_tiles/ntp_tiles_browsertest.cc',
        }
        touched = {line[6:] for line in self.text.splitlines() if line.startswith('+++ b/')}
        self.assertEqual(touched, expected)
        self.assertEqual(set(self.group['postimageSHA256']), expected)
        self.assertEqual(set(self.group['incrementalPreimageSHA256']), expected)
        # Preserve the existing engine definitions and preference load/precedence.
        self.assertNotIn('+++ b/third_party/search_engines_data/', self.text)
        self.assertNotIn('+++ b/components/search_engines/default_search_manager.cc', self.text)

    def test_patch_contains_behavioral_privacy_and_persisted_choice_regressions(self):
        self.assertIn('NeAntikSubmittedQueryFallback', self.text)
        self.assertIn('NeAntikPreservesExplicitSearchChoices', self.text)
        self.assertIn('auto reloaded = create_manager();', self.text)
        self.assertIn('GetEngineFromFullList(1)', self.text)
        self.assertIn('EXPECT_EQ(DefaultSearchManager::FROM_USER, source)', self.text)
        for field in ('suggestions_url', 'image_url', 'new_tab_url', 'favicon_url',
                      'preconnect_to_search_url', 'prefetch_likely_navigations'):
            self.assertIn('engine->' + field, self.text)
        self.assertIn('https://duckduckgo.com/?q={searchTerms}', self.text)


if __name__ == '__main__':
    unittest.main()
