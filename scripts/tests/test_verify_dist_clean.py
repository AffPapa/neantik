import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-dist-clean.py"
SPEC = importlib.util.spec_from_file_location("verify_dist_clean", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DistCleanVerifierTests(unittest.TestCase):
    def test_clean_dist_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "dist").mkdir()
            (root / "dist" / "artifact.zip").write_text("ok", encoding="utf-8")

            self.assertEqual(MODULE.verify_dist_clean(dist_root=root / "dist"), [])

    def test_ds_store_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "dist").mkdir()
            (root / "dist" / ".DS_Store").write_bytes(b"finder")

            with self.assertRaisesRegex(MODULE.DistCleanError, "Finder metadata"):
                MODULE.verify_dist_clean(dist_root=root / "dist")

    def test_appledouble_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "dist" / "nested").mkdir(parents=True)
            (root / "dist" / "nested" / "._artifact.zip").write_bytes(b"finder")

            with self.assertRaisesRegex(MODULE.DistCleanError, "Finder metadata"):
                MODULE.verify_dist_clean(dist_root=root / "dist")


if __name__ == "__main__":
    unittest.main()
