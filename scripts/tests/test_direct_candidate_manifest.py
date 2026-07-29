import importlib.util
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "direct-candidate-manifest.py"
SPEC = importlib.util.spec_from_file_location("direct_candidate_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

VERIFIER_TESTS = (
    Path(__file__).resolve().parent / "test_verify_gui_fingerprint_report.py"
)
VERIFIER_SPEC = importlib.util.spec_from_file_location(
    "test_verify_gui_fingerprint_report_for_candidate_manifest",
    VERIFIER_TESTS,
)
assert VERIFIER_SPEC and VERIFIER_SPEC.loader
FIXTURES = importlib.util.module_from_spec(VERIFIER_SPEC)
sys.modules[VERIFIER_SPEC.name] = FIXTURES
VERIFIER_SPEC.loader.exec_module(FIXTURES)


def prepared_fixture(root: Path) -> Path:
    app = FIXTURES.write_integrated_app_fixture(root)
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as file:
        info = plistlib.load(file)
    info["CFBundleIdentifier"] = "app.neantik.desktop"
    info["CFBundleExecutable"] = "NeAntik"
    with info_path.open("wb") as file:
        plistlib.dump(info, file)
    executable = app / "Contents/MacOS/NeAntik"
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_bytes(b"manager executable")
    return app


class DirectCandidateManifestTests(unittest.TestCase):
    def test_round_trip_binds_code_critical_candidate_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            created_sha = MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(app, release_channel="public-alpha"),
            )
            verified_sha = MODULE.verify_manifest(
                app,
                manifest,
                release_channel="public-alpha",
            )
            self.assertEqual(created_sha, verified_sha)
            self.assertNotIn(str(root), manifest.read_text(encoding="utf-8"))

    def test_rejects_manager_executable_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(app, release_channel="public-alpha"),
            )
            (app / "Contents/MacOS/NeAntik").write_bytes(b"changed")
            with self.assertRaisesRegex(MODULE.CandidateManifestError, "changed after"):
                MODULE.verify_manifest(
                    app,
                    manifest,
                    release_channel="public-alpha",
                )

    def test_rejects_unlisted_helper_or_signature_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            helper = (
                app
                / "Contents/Resources/NeAntik Browser.app/Contents/Frameworks"
                / "NeAntik Helper.app/Contents/MacOS/NeAntik Helper"
            )
            helper.parent.mkdir(parents=True)
            helper.write_bytes(b"helper executable")
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(app, release_channel="public-alpha"),
            )
            helper.write_bytes(b"changed helper executable")
            with self.assertRaisesRegex(MODULE.CandidateManifestError, "changed after"):
                MODULE.verify_manifest(
                    app,
                    manifest,
                    release_channel="public-alpha",
                )

    def test_allows_only_documented_stapler_ticket_path_to_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            ticket = app / "Contents/CodeResources"
            ticket.write_bytes(b"before staple")
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(app, release_channel="public-alpha"),
            )
            ticket.write_bytes(b"after staple")
            MODULE.verify_manifest(
                app,
                manifest,
                release_channel="public-alpha",
            )

    def test_rejects_release_channel_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(app, release_channel="public-alpha"),
            )
            with self.assertRaisesRegex(
                MODULE.CandidateManifestError,
                "release channel",
            ):
                MODULE.verify_manifest(
                    app,
                    manifest,
                    release_channel="production",
                )

    def test_rejects_gui_evidence_created_before_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(
                    app,
                    release_channel="public-alpha",
                    prepared_at="2026-07-25T09:00:00Z",
                ),
            )
            evidence = root / "fingerprint-audit.json"
            evidence.write_text(
                json.dumps(FIXTURES.production_report()),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(MODULE.CandidateManifestError, "predates"):
                MODULE.verify_evidence_follows_manifest(manifest, evidence)


if __name__ == "__main__":
    unittest.main()
