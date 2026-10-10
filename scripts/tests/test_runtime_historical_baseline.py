import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runtime_historical_baseline import bound_baseline_path


class HistoricalBaselineTests(unittest.TestCase):
    def test_current_gate_refresh_keeps_exact_historical_source_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            old = b'{"minimumPublicChromiumVersion":"154.0.8037.98"}\n'
            sha = hashlib.sha256(old).hexdigest()
            current = runtime / "security-baseline.json"
            current.write_bytes(old)
            self.assertEqual(bound_baseline_path(runtime, sha), current)
            archive = runtime / "security-baselines" / f"{sha}.json"
            archive.parent.mkdir()
            archive.write_bytes(old)
            current.write_bytes(b'{"minimumPublicChromiumVersion":"155.0.8059.40"}\n')
            self.assertEqual(bound_baseline_path(runtime, sha), archive)
            self.assertIn(b"155.0.8059.40", current.read_bytes())
            archive.write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                bound_baseline_path(runtime, sha)

    def test_unsafe_or_unbound_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = b"baseline"
            sha = hashlib.sha256(data).hexdigest()
            (root / "source").write_bytes(data)
            (root / "security-baselines").mkdir()
            archive = root / "security-baselines" / f"{sha}.json"
            archive.symlink_to(root / "source")
            for value in (sha, "../source", None):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    bound_baseline_path(root, value)
