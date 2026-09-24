import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "neantik-release-evidence-summary.py"
SPEC = importlib.util.spec_from_file_location("release_summary", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ReleaseEvidenceSummaryTests(unittest.TestCase):
    def test_reports_recorded_release_as_stale_and_current_gates_as_not_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "releases").mkdir()
            (root / "dist").mkdir()
            (root / "releases" / "v0.7.8.json").write_text(json.dumps({
                "tag": "v0.7.8", "version": "0.7.8", "build": 71,
                "runtime": {"chromiumVersion": "153.0.8010.52"},
                "rollbackRelease": "v0.7.7",
                "verification": {"developerId": "passed", "gatekeeper": "passed"},
            }))
            with patch.object(MODULE, "ROOT", root), patch.object(
                MODULE, "run_git", side_effect=["abc123456789", "audit", "M file"]
            ):
                result = MODULE.summary()
        self.assertEqual(result["checkout"]["state"], "blocked")
        self.assertEqual(result["latestRecordedRelease"]["state"], "stale")
        self.assertEqual(result["candidateGates"]["gatekeeper"], "not-run")
        self.assertEqual(result["latestRecordedRelease"]["tag"], "v0.7.8")
        rendered = json.dumps(result)
        self.assertNotIn(temporary, rendered)
        self.assertNotIn("fingerprint-audit.json", rendered)

    def test_dirty_or_malformed_candidate_never_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "releases").mkdir()
            (root / "dist").mkdir()
            (root / "dist" / "direct-candidate-manifest.json").write_text("{")
            (root / "dist" / "direct-candidate-source.json").write_text("{}")
            with patch.object(MODULE, "ROOT", root), patch.object(
                MODULE, "run_git", side_effect=["abc123456789", "audit", ""]
            ):
                result = MODULE.summary()
        self.assertEqual(result["candidate"]["state"], "invalid")

    def test_symlinked_candidate_is_invalid_without_reading_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "releases").mkdir()
            (root / "dist").mkdir()
            secret = root / "outside.json"
            secret.write_text('{"version":"9.9.9","private":"do-not-emit"}')
            (root / "dist" / "direct-candidate-manifest.json").symlink_to(secret)
            (root / "dist" / "direct-candidate-source.json").write_text("{}")
            with patch.object(MODULE, "ROOT", root), patch.object(
                MODULE, "run_git", side_effect=["abc123456789", "audit", ""]
            ):
                result = MODULE.summary()
        self.assertEqual(result["candidate"]["state"], "invalid")
        self.assertNotIn("do-not-emit", json.dumps(result))

    def test_git_status_failure_blocks_candidate_even_with_matching_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "releases").mkdir()
            dist = root / "dist"
            dist.mkdir()
            manifest_bytes = b'{"schemaVersion":1}'
            (dist / "direct-candidate-manifest.json").write_bytes(manifest_bytes)
            (dist / "direct-candidate-source.json").write_text(json.dumps({
                "commit": "a" * 40,
                "tree": "b" * 40,
                "manifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
            }))
            with patch.object(MODULE, "ROOT", root), patch.object(
                MODULE, "run_git", side_effect=["a" * 40, "audit", None, "b" * 40]
            ):
                result = MODULE.summary()
        self.assertEqual(result["checkout"]["state"], "blocked")
        self.assertEqual(result["candidate"]["state"], "blocked")

    def test_release_record_text_is_strictly_sanitized(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "releases").mkdir()
            (root / "dist").mkdir()
            private = "credential-like-sensitive-value"
            (root / "releases" / "v1.2.3.json").write_text(json.dumps({
                "tag": private, "version": "1.2.3", "build": 7,
                "runtime": {"chromiumVersion": private},
                "rollbackRelease": private,
                "verification": {"developerId": private, "gatekeeper": "passed"},
            }))
            with patch.object(MODULE, "ROOT", root), patch.object(
                MODULE, "run_git", side_effect=["a" * 40, "audit", ""]
            ):
                result = MODULE.summary()
        rendered = json.dumps(result)
        self.assertNotIn(private, rendered)
        self.assertEqual(result["latestRecordedRelease"]["state"], "invalid")
        self.assertEqual(result["latestRecordedRelease"]["recordedGates"]["developerId"], "unknown")


if __name__ == "__main__":
    unittest.main()
