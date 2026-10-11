import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("manager_baseline", SCRIPTS / "package-manager-release-baseline.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ManagerBaselineTests(unittest.TestCase):
    def fixture(self, root):
        project = root / "project"
        runtime = project / "runtime"
        (runtime / "security-baselines").mkdir(parents=True)
        evidence = root / "candidate/Contents/Resources/NeAntikRuntimeEvidence"
        evidence.mkdir(parents=True)
        old = b'{"checkedAt":"2026-10-10"}\n'
        new = b'{"checkedAt":"2026-10-11"}\n'
        digest = hashlib.sha256(old).hexdigest()
        (runtime / "security-baselines" / (digest + ".json")).write_bytes(old)
        (runtime / "security-baseline.json").write_bytes(new)
        (evidence / "security-baseline.json").write_bytes(old)
        (evidence / "runtime-verification.json").write_text(json.dumps({"securityBaselineSHA256": digest}))
        return project, evidence, old, new

    def test_daily_refresh_preserves_original_and_packages_current(self):
        with tempfile.TemporaryDirectory() as temporary:
            project, evidence, old, new = self.fixture(Path(temporary))
            original_report = (evidence / "runtime-verification.json").read_bytes()
            module.package(project, evidence)
            module.package(project, evidence)  # Idempotent same observation.
            module.verify(project, evidence)
            self.assertEqual((evidence / "security-baseline.json").read_bytes(), old)
            self.assertEqual((evidence / "runtime-verification.json").read_bytes(), original_report)
            self.assertEqual((evidence / "release-security-baseline.json").read_bytes(), new)
            self.assertEqual(list(evidence.glob(".release-baseline-*")), [])

    def test_fresh_observation_cannot_replace_historical_trust_or_be_omitted(self):
        with tempfile.TemporaryDirectory() as temporary:
            project, evidence, _, _ = self.fixture(Path(temporary))
            with self.assertRaises(ValueError): module.verify(project, evidence)
            module.package(project, evidence)
            (evidence / "release-security-baseline.json").write_bytes(b"stale")
            with self.assertRaises(ValueError): module.verify(project, evidence)

    def test_integrated_gate_uses_read_only_shared_verification(self):
        text = (SCRIPTS / "verify-integrated-release.sh").read_text()
        self.assertIn('package-manager-release-baseline.py', text)
        self.assertIn('--evidence "$EVIDENCE" --verify-only', text)
        self.assertIn('verify-packaged-runtime-report.py', text)

    def test_mismatched_history_cannot_be_repaired_by_fresh_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            project, evidence, _, _ = self.fixture(Path(temporary))
            (evidence / "security-baseline.json").write_bytes(b"tampered")
            with self.assertRaises(ValueError): module.package(project, evidence)
            self.assertFalse((evidence / "release-security-baseline.json").exists())

    def test_no_overwrite_of_different_existing_release_or_symlink(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as temporary:
                project, evidence, _, _ = self.fixture(Path(temporary))
                external = Path(temporary) / "external"
                external.write_bytes(b"unchanged")
                destination = evidence / "release-security-baseline.json"
                if symlink: destination.symlink_to(external)
                else: destination.write_bytes(b"unrelated")
                with self.assertRaises(ValueError): module.package(project, evidence)
                self.assertEqual(external.read_bytes(), b"unchanged")

    def test_missing_historical_binding_refuses(self):
        with tempfile.TemporaryDirectory() as temporary:
            project, evidence, _, _ = self.fixture(Path(temporary))
            for path in (project / "runtime/security-baselines").iterdir(): path.unlink()
            with self.assertRaises(ValueError): module.package(project, evidence)
            self.assertFalse((evidence / "release-security-baseline.json").exists())


if __name__ == "__main__": unittest.main()
