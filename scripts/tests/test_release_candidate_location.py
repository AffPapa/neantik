import json
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_candidate_location as location


class CandidateLocationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve()
        (self.project / "dist").mkdir(mode=0o700)
        self.root = location.create(self.project)

    def test_private_registered_location_and_legacy_path(self):
        self.assertEqual(location.validate(self.project, self.root), self.root)
        app = self.root / "NeAntik.app"
        app.mkdir()
        manifest = self.root / "direct-candidate-manifest.json"
        self.assertEqual(location.validate_inputs(self.project, app, {manifest.name:manifest}), self.root)
        self.assertEqual(location.validate_inputs(self.project, self.project / "dist/NeAntik.app", {}), self.project / "dist")

    def test_registration_cannot_be_copied_to_another_inode(self):
        other = location.create(self.project)
        (other / "location.json").unlink()
        shutil.copyfile(self.root / "location.json", other / "location.json")
        (other / "location.json").chmod(0o400)
        with self.assertRaises(location.CandidateLocationError):
            location.validate(self.project, other)

    def test_alias_root_marker_link_and_hardlink_are_refused(self):
        alias = self.root.parent / "alias"
        alias.symlink_to(self.root)
        with self.assertRaises(location.CandidateLocationError):
            location.validate(self.project, alias)
        marker = self.root / "location.json"
        marker.unlink()
        marker.symlink_to(self.root.parent / "missing")
        with self.assertRaises(OSError):
            location.validate(self.project, self.root)
        marker.unlink()
        other = location.create(self.project)
        os.link(other / "location.json", marker)
        with self.assertRaises(location.CandidateLocationError):
            location.validate(self.project, self.root)

    def test_nonprivate_directory_and_mutable_registration_refuse(self):
        self.root.chmod(0o755)
        with self.assertRaises(location.CandidateLocationError):
            location.validate(self.project, self.root)
        self.root.chmod(0o700)
        (self.root / "location.json").chmod(0o600)
        with self.assertRaises(location.CandidateLocationError):
            location.validate(self.project, self.root)

    def test_mixed_metadata_wrong_name_and_unregistered_app_refuse(self):
        for app, inputs in (
            (self.root / "Different.app", {}),
            (self.root / "NeAntik.app", {"direct-candidate-manifest.json":self.project / "dist/direct-candidate-manifest.json"}),
            (self.project / "dist/unregistered/NeAntik.app", {})):
            with self.subTest(app=app), self.assertRaises((location.CandidateLocationError,OSError)):
                location.validate_inputs(self.project, app, inputs)

    def test_changed_extra_or_duplicate_registration_refuse(self):
        marker = self.root / "location.json"
        for payload in (b'{"schemaVersion":1,"schemaVersion":1}', b'{}', b'[]'):
            marker.chmod(0o600)
            marker.write_bytes(payload)
            marker.chmod(0o400)
            with self.assertRaises(location.CandidateLocationError):
                location.validate(self.project, self.root)

    def test_all_pipeline_scripts_share_the_validated_override(self):
        root = Path(__file__).resolve().parents[2]
        for filename in ("Release-NeAntik.command", "scripts/Run-NeAntik-Release.command",
                         "scripts/prepare-direct-manager-update.sh", "scripts/release-direct.sh",
                         "scripts/notarize-direct-candidate.sh", "scripts/release-direct-dmg.sh"):
            text = (root / filename).read_text()
            self.assertIn("NEANTIK_DIRECT_CANDIDATE_ROOT", text)
            self.assertIn('release_candidate_location.py', text)
            self.assertIn('--validate "$NEANTIK_DIRECT_CANDIDATE_ROOT"', text)
        outer = (root / "Release-NeAntik.command").read_text()
        self.assertLess(outer.index('--floor-only'), outer.index('mv "$artifact"'))
        launcher = (root / "scripts/Run-NeAntik-Release.command").read_text()
        self.assertEqual(launcher.count('--summary-output "$SUMMARY_PATH"'), 3)
        self.assertIn('SUMMARY_PATH="$CANDIDATE_ROOT/fingerprint-audit-summary.json"', launcher)

    def test_real_collector_preparation_preserves_flat_summary_sentinel(self):
        script = Path(__file__).resolve().parents[1] / "collect-gui-fingerprint-evidence.py"
        spec = importlib.util.spec_from_file_location("candidate_location_collector", script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        old_summary = self.project / "dist/fingerprint-audit-summary.json"
        old_summary.write_bytes(b"keep existing release evidence")
        output = self.root / "fingerprint-audit.json"
        summary = self.root / "fingerprint-audit-summary.json"
        output.write_bytes(b"previous owned report")
        summary.write_bytes(b"previous owned summary")
        audits = self.root / "audits"
        audits.mkdir()
        state = self.root / "attempt"
        module.prepare_attempt_state(audits_dir=audits, output=output,
                                     summary_output=summary, state_dir=state)
        self.assertEqual(old_summary.read_bytes(), b"keep existing release evidence")
        self.assertEqual((state / "previous-fingerprint-audit-summary.json").read_bytes(), b"previous owned summary")


if __name__ == "__main__":
    unittest.main()
