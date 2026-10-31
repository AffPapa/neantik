import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "complete-chromium-15680-build-evidence.py"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("complete_chromium_15680_build_evidence", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CompleteChromium15680BuildEvidenceTests(unittest.TestCase):
    def executable(self, path: Path, version: str) -> Path:
        path.write_text(f"#!/bin/sh\nprintf '%s\\n' 'Chromium {version}'\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    def test_ignores_stale_74_bundle_when_single_80_binary_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old_app = self.executable(root / "stale-app", "156.0.8078.74")
            current = self.executable(root / "chrome", "156.0.8078.80")

            browser, version = MODULE.select_chromium_browser([old_app, current])

            self.assertEqual(browser, current)
            self.assertIn("156.0.8078.80", version)

    def test_rejects_two_exact_version_binaries_as_ambiguous(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = self.executable(root / "chrome", "156.0.8078.80")
            second = self.executable(root / "app-binary", "156.0.8078.80")

            with self.assertRaisesRegex(MODULE.evidence.M15680EvidenceError, "exactly one executable"):
                MODULE.select_chromium_browser([first, second])

    def test_rejects_stale_only_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            old = self.executable(Path(temporary) / "stale-app", "156.0.8078.74")

            with self.assertRaisesRegex(MODULE.evidence.M15680EvidenceError, "156.0.8078.80"):
                MODULE.select_chromium_browser([old])

    def test_selects_version_pinned_framework_and_ignores_stale_app_and_dsym(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            current = (output / "NeAntik Browser Framework.framework" / "Versions" /
                       "156.0.8078.80" / "NeAntik Browser Framework")
            current.parent.mkdir(parents=True)
            current.write_bytes(b"current-framework")
            stale = (output / "NeAntik Browser.app" / "Contents" / "Frameworks" /
                     "NeAntik Browser Framework.framework" / "Versions" /
                     "156.0.8078.74" / "NeAntik Browser Framework")
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"stale-framework")
            dsym = (output / "NeAntik Browser.app.dSYM" / "Contents" / "Resources" /
                    "DWARF" / "NeAntik Browser Framework")
            dsym.parent.mkdir(parents=True)
            dsym.write_bytes(b"stale-dsym")

            self.assertEqual(MODULE.select_chromium_framework(output), current)

    def test_rejects_missing_pinned_framework_even_if_stale_framework_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            stale = (output / "NeAntik Browser.app" / "Contents" / "Frameworks" /
                     "NeAntik Browser Framework.framework" / "Versions" /
                     "156.0.8078.74" / "NeAntik Browser Framework")
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"stale-framework")

            with self.assertRaisesRegex(MODULE.evidence.M15680EvidenceError, "156.0.8078.80"):
                MODULE.select_chromium_framework(output)


if __name__ == "__main__":
    unittest.main()
