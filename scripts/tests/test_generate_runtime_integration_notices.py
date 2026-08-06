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

        self.assertEqual(rendered, checked_in)
        self.assertIn("Chromium: `151.0.7922.75`", rendered)
        self.assertIn(
            "Source contract binary binding: `pending-new-build`", rendered
        )
        self.assertIn("1ddc0a2003eb30c3990568d74ed0437451e9c374", rendered)
        self.assertIn("e194927e4838cb66ecdef40843a97c4f88f8d2af", rendered)
        self.assertIn("Owned patchset status: `release-ready`", rendered)
        self.assertNotIn("25 July 2026", rendered)

    def test_schema_four_nested_packaging_license_is_source_bound(self) -> None:
        rendered = MODULE.render_notices(project_root=ROOT)

        expected = (
            ROOT
            / "runtime"
            / "chromium-151-source-contract.json"
        )
        source_contract = MODULE.load_json(expected)
        packaging = source_contract["macPackaging"]
        license_sha256 = packaging["criticalFiles"]["LICENSE"]
        self.assertIn(f"License SHA-256: `{license_sha256}`", rendered)

    def test_changed_source_contract_license_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            shutil.copytree(ROOT / "runtime", fixture / "runtime")
            contract_path = (
                fixture / "runtime" / "chromium-151-source-contract.json"
            )
            contract = MODULE.load_json(contract_path)
            contract["macPackaging"]["criticalFiles"]["LICENSE"] = "0" * 64
            contract_path.write_text(
                json.dumps(contract),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.RuntimeNoticesError,
                "license SHA-256 differ",
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
