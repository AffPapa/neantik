import importlib.util
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
        self.assertIn("Chromium: `150.0.7871.186`", rendered)
        self.assertIn(
            "Next candidate source binary binding: `pending-new-build`", rendered
        )
        self.assertIn("9cbd94c2b8f6f2a58a80bf32b3e01b68f3d129d4", rendered)
        self.assertIn("fd0378e4f20fa09e21b09beca71573d435d787cf", rendered)
        self.assertIn("Owned patchset status: `release-ready`", rendered)
        self.assertNotIn("25 July 2026", rendered)

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
