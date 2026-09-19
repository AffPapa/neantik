import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('public_args', Path(__file__).parents[1] / 'verify_public_build_args.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublicBuildArgsTests(unittest.TestCase):
    def test_reviewed_assignments_and_empty_credentials(self):
        self.assertEqual(MODULE.verify('target_cpu="arm64"\nangle_enable_metal=true\ngoogle_api_key=""\n'), 3)

    def test_rejects_comments_paths_unknown_keys_and_credentials_without_echo(self):
        for text in ('# /Users/alice/private-canary/build', 'google_api_key="private-canary"',
                     'unknown_key="private-canary"', 'target_cpu="/private-canary"',
                     'is_debug=false # private-canary', ''):
            with self.subTest(text=text), self.assertRaises(ValueError) as caught:
                MODULE.verify(text)
            self.assertNotIn('private-canary', str(caught.exception))
