import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "generate-runtime-integration-notices.py"
SPEC = importlib.util.spec_from_file_location(
    "generate_runtime_integration_notices",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class RuntimeIntegrationNoticesTests(unittest.TestCase):
    def test_checked_in_notices_equal_fresh_public_metadata_render(self) -> None:
        rendered = MODULE.render_notices(project_root=ROOT)
        checked_in = (
            ROOT / "docs" / "RUNTIME_INTEGRATION_NOTICES.md"
        ).read_text(encoding="utf-8")
        runtime_lock = MODULE.load_json(
            ROOT / "runtime" / "fingerprint-chromium.lock.json"
        )
        source_contract = MODULE.load_json(
            ROOT / "runtime" / "chromium-152-source-contract.json"
        )
        chromium_version = runtime_lock["fingerprintChromium"][
            "chromiumVersion"
        ]
        common_commit = runtime_lock["commonChromium"]["commit"]
        packaging_commit = runtime_lock["macPackaging"]["commit"]

        self.assertEqual(rendered, checked_in)
        self.assertIn(f"Chromium: `{chromium_version}`", rendered)
        self.assertIn(
            "Source contract binary binding: `pending-new-build`", rendered
        )
        self.assertIn(
            f"Source contract candidate: `{source_contract['targetChromiumVersion']}`",
            rendered,
        )
        self.assertIn(common_commit, rendered)
        self.assertIn(packaging_commit, rendered)
        self.assertIn("Owned patchset status: `release-ready`", rendered)
        self.assertNotIn("25 July 2026", rendered)

    def test_schema_four_nested_packaging_license_is_runtime_bound(self) -> None:
        rendered = MODULE.render_notices(project_root=ROOT)

        expected = (
            ROOT
            / "runtime"
            / "fingerprint-chromium.lock.json"
        )
        runtime_lock = MODULE.load_json(expected)
        packaging = runtime_lock["macPackaging"]
        license_sha256 = packaging["criticalFiles"]["LICENSE"]
        self.assertIn(f"License SHA-256: `{license_sha256}`", rendered)

    def test_source_candidate_must_remain_pending_until_runtime_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            shutil.copytree(ROOT / "runtime", fixture / "runtime")
            runtime_lock_path = (
                fixture / "runtime" / "fingerprint-chromium.lock.json"
            )
            runtime_lock = MODULE.load_json(runtime_lock_path)
            runtime_lock["fingerprintChromium"]["chromiumVersion"] = (
                "151.0.7922.108"
            )
            runtime_lock_path.write_text(
                json.dumps(runtime_lock),
                encoding="utf-8",
            )
            contract_path = (
                fixture / "runtime" / "chromium-152-source-contract.json"
            )
            contract = MODULE.load_json(contract_path)
            contract["binaryBindingStatus"] = "bound-to-binary"
            contract_path.write_text(
                json.dumps(contract),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.RuntimeNoticesError,
                "only while its binary binding is pending-new-build",
            ):
                MODULE.render_notices(project_root=fixture)

    def test_changed_locked_license_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            shutil.copytree(ROOT / "runtime", fixture / "runtime")
            chromium_license = fixture / "runtime" / "licenses" / "Chromium-LICENSE"
            chromium_license.write_text(
                chromium_license.read_text(encoding="utf-8") + "\ndrift\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.RuntimeNoticesError,
                "license SHA-256 mismatch",
            ):
                MODULE.render_notices(project_root=fixture)

    def test_integrated_packager_checks_generated_notices(self) -> None:
        packager = (
            ROOT / "scripts" / "package-integrated-app.sh"
        ).read_text(encoding="utf-8")
        check = "generate-runtime-integration-notices.py\" --check"
        copy = 'docs/RUNTIME_INTEGRATION_NOTICES.md"'

        self.assertIn(check, packager)
        self.assertIn(copy, packager)
        self.assertLess(packager.index(check), packager.index(copy))


if __name__ == "__main__":
    unittest.main()
