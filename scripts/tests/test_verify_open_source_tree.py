from __future__ import annotations

import importlib.util
import io
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
    def test_provisioning_profiles_are_forbidden_from_public_source(self) -> None:
        self.assertIn(".provisionprofile", MODULE.FORBIDDEN_SUFFIXES)
        self.assertIn(".mobileprovision", MODULE.FORBIDDEN_SUFFIXES)

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
