from __future__ import annotations

import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts" / "verify-open-source-tree.py"
SPEC = importlib.util.spec_from_file_location("verify_open_source_tree", VERIFIER)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OpenSourceTreePrivacyTests(unittest.TestCase):
    def test_current_zip_and_dmg_checksums_and_negative_controls(self) -> None:
        import copy
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "releases").mkdir()
            artifacts = [{"name": "NeAntik-1.2.3-arm64-notarized." + suffix,
                          "sha256": char * 64} for suffix, char in (("zip", "a"), ("dmg", "b"))]
            metadata = {"version": "1.2.3", "artifacts": artifacts}
            for artifact in artifacts:
                (root / "releases" / (artifact["name"] + ".sha256")).write_text(
                    artifact["sha256"] + "  " + artifact["name"] + "\n")
            with mock.patch.object(MODULE, "PROJECT_ROOT", root):
                MODULE.verify_release_checksums(metadata)
                MODULE.verify_release_checksums({"version": "1.2.3", "archive": artifacts[0]})
                broken = []
                for replacement in ([], [artifacts[0]], [artifacts[0], artifacts[0]]):
                    broken.append({"version": "1.2.3", "artifacts": replacement})
                for field, value in (("name", "../outside.zip"), ("sha256", "c" * 64),
                                     ("sha256", "not-a-digest")):
                    candidate = copy.deepcopy(metadata)
                    candidate["artifacts"][1][field] = value
                    broken.append(candidate)
                broken.append({**metadata, "archive": {**artifacts[0], "sha256": "c" * 64}})
                broken.append({**metadata, "archive": artifacts[1]})
                broken.append({"version": "1.2.3"})
                for candidate in broken:
                    with self.subTest(candidate=candidate), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                        MODULE.verify_release_checksums(candidate)
                (root / "releases" / (artifacts[1]["name"] + ".sha256")).unlink()
                with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    MODULE.verify_release_checksums(metadata)

    def test_ci_contract_detects_a_required_suite_removed_from_shards(self) -> None:
        required = {"UpdateManifestTests", "BrowserProcessInventoryTests",
                    "FingerprintEvidenceEnrollmentTests", "ProfileOrganizationTests",
                    "SecureEnclaveFingerprintEvidenceSignerTests"}
        MODULE.verify_ci_suite_coverage(required)
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            MODULE.verify_ci_suite_coverage(required - {"UpdateManifestTests"})

    def test_markdown_public_release_record_is_parsed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v0.7.3.md"
            path.write_text("# NeAntik 0.7.3 (66)\n", encoding="utf-8")
            self.assertEqual(
                MODULE.read_markdown_release(path),
                ((0, 7, 3), 66),
            )

    def test_older_development_preview_requires_bilingual_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text(
                "Локальный кандидат `0.3.20 (23)` — это development preview.\n",
                encoding="utf-8",
            )
            (root / "README.en.md").write_text(
                "The local `0.3.20 (23)` candidate is a development preview.\n",
                encoding="utf-8",
            )
            with mock.patch.object(MODULE, "PROJECT_ROOT", root):
                self.assertTrue(
                    MODULE.has_explicit_development_preview_marker("0.3.20", "23")
                )
                (root / "README.en.md").write_text(
                    "The local `0.3.20 (23)` candidate is current.\n",
                    encoding="utf-8",
                )
                self.assertFalse(
                    MODULE.has_explicit_development_preview_marker("0.3.20", "23")
                )

    def test_personal_absolute_user_path_is_rejected(self) -> None:
        leaked = "/" + "Users/" + "release-operator/private/report.json"
        self.assertEqual(
            MODULE.text_violation(Path("README.md"), leaked),
            "personal absolute path",
        )

    def test_private_deployment_endpoint_is_rejected(self) -> None:
        leaked = "deploy with " + "root" + "@" + "198.51.100.77"
        self.assertEqual(
            MODULE.text_violation(Path("docs/release.md"), leaked),
            "private deployment endpoint",
        )

    def test_absolute_secret_store_path_is_rejected(self) -> None:
        leaked = (
            "/"
            + "home/"
            + "release-operator/project/"
            + ".secrets/ssh/signing-key"
        )
        self.assertEqual(
            MODULE.text_violation(Path("scripts/release.sh"), leaked),
            "private secret-store path",
        )

    def test_synthetic_user_paths_are_limited_to_test_fixtures(self) -> None:
        synthetic = "/" + "Users/" + "alice/private-fixture"
        self.assertIsNone(
            MODULE.text_violation(
                Path("scripts/tests/test_privacy_fixture.py"), synthetic
            )
        )
        self.assertEqual(
            MODULE.text_violation(Path("README.md"), synthetic),
            "personal absolute path",
        )

    def test_verifier_scans_its_own_source_without_a_blind_spot(self) -> None:
        with mock.patch.object(
            MODULE,
            "text_violation",
            return_value="synthetic self-test violation",
        ):
            stderr = io.StringIO()
            with redirect_stderr(stderr), self.assertRaises(SystemExit):
                MODULE.verify_files([VERIFIER])
        self.assertIn("scripts/verify-open-source-tree.py", stderr.getvalue())

    def test_real_operational_markers_are_not_stored_in_verifier(self) -> None:
        text = VERIFIER.read_text(encoding="utf-8")
        self.assertNotIn("/" + "Users/" + "dumay", text)
        self.assertNotIn("root" + "@" + "135.181.253.143", text)
        self.assertNotIn(
            "/" + "Users/" + "dumay/AFF.job/" + ".secrets",
            text,
        )


if __name__ == "__main__":
    unittest.main()
