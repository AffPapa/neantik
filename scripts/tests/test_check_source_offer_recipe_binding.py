import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('recipe_binding', Path(__file__).parents[1] / 'check-source-offer-recipe-binding.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecipeBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'recipe.md').write_bytes(b'recipe')
        digest = hashlib.sha256(b'recipe').hexdigest()
        self.manifest = {'webkitBuildRecipe': {'path': 'recipe.md', 'sha256': digest},
                         'sourceOfferComponents': [{'path': 'recipe.md', 'sha256': digest, 'bytes': 6, 'includedInOfferFolder': True}]}

    def run_check(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))
        module.check(self.root)

    def test_matching_recipe_passes(self):
        self.run_check()

    def test_stale_top_level_digest_is_refused(self):
        self.manifest['webkitBuildRecipe']['sha256'] = '0' * 64
        with self.assertRaises(ValueError): self.run_check()

    def test_missing_or_duplicate_component_is_refused(self):
        row = self.manifest['sourceOfferComponents'].pop()
        with self.assertRaises(ValueError): self.run_check()
        self.manifest['sourceOfferComponents'] = [row, row]
        with self.assertRaises(ValueError): self.run_check()

    def test_changed_file_and_path_escape_are_refused(self):
        (self.root / 'recipe.md').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.run_check()
        self.manifest['webkitBuildRecipe']['path'] = '../recipe.md'
        with self.assertRaises(ValueError): self.run_check()


if __name__ == '__main__': unittest.main()
