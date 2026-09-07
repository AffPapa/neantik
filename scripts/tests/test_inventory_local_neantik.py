import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("inventory_local", Path(__file__).parents[1] / "inventory-local-neantik.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalInventoryTests(unittest.TestCase):
    def test_outer_bundle_prunes_nested_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "NeAntik-Dev.app"
            (app / "Contents/NeAntik Browser.app").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.3.24", "CFBundleVersion": "27"}))
            items, errors = module.inventory([root, root])
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0]["version"], "0.3.24 (27)")
            self.assertEqual(errors, [])
            self.assertTrue(app.exists())

    def test_archives_and_unknown_bundles_are_reported_not_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "NeAntik-old.app").mkdir()
            archive = root / "NeAntik-old.dmg"
            archive.write_bytes(b"fixture")
            items, errors = module.inventory([root])
            self.assertEqual(len(items), 2)
            self.assertEqual(len(errors), 1)
            self.assertEqual(archive.read_bytes(), b"fixture")

    def test_symlinked_apps_are_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "NeAntik-link.app").symlink_to("/Applications", target_is_directory=True)
            self.assertEqual(module.inventory([root]), ([], []))

    def test_report_includes_history_and_scope_limit(self):
        report = module.render([], [], [Path("/nonexistent-scan-root")], [{"original": "/nonexistent-old.app", "trash": "/nonexistent-trash.app"}])
        self.assertIn("/nonexistent-old.app", report)
        self.assertIn("/nonexistent-trash.app", report)
        self.assertIn("не сканирование всех дисков", report)


if __name__ == "__main__":
    unittest.main()
