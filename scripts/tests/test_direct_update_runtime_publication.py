import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runtime_pins", SCRIPTS / "verify-direct-update-runtime-pins.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicationClosureTests(unittest.TestCase):
    def test_date_only_refresh_preserves_history_but_history_tamper_does_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            history = root / "security-baseline.json"
            history.write_bytes(b"immutable build baseline")
            release = root / "release-security-baseline.json"
            release.write_bytes(b'{"checkedAt":"2026-10-11"}')
            os.chmod(release, 0o600)
            first = module.measure(root, "evidence")
            release.write_bytes(b'{"checkedAt":"2026-10-12"}')
            self.assertEqual(first, module.measure(root, "evidence"))
            history.write_bytes(b"corrupt build baseline")
            self.assertNotEqual(first, module.measure(root, "evidence"))

    def test_only_fixed_regular_bounded_publication_leaf_is_separate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "release-security-baseline.json"
            release.write_bytes(b"publication")
            os.chmod(release, 0o644)
            with self.assertRaises(ValueError): module.measure(root, "evidence")
            os.chmod(release, 0o600)
            first = module.measure(root, "evidence")
            release.rename(root / "different-baseline.json")
            self.assertNotEqual(first, module.measure(root, "evidence"))

    def test_manager_packaging_checks_the_actual_candidate_pins(self):
        source = (SCRIPTS / "prepare-direct-manager-update.sh").read_text()
        self.assertIn('verify-direct-update-runtime-pins.py" --reference-app "$CANDIDATE_APP"', source)


if __name__ == "__main__": unittest.main()
