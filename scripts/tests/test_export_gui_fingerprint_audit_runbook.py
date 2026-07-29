import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "export-gui-fingerprint-audit-runbook.py"
SPEC = importlib.util.spec_from_file_location("export_gui_fingerprint_audit_runbook", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GuiFingerprintAuditRunbookTests(unittest.TestCase):
    def test_runbook_records_archive_hash_and_release_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_fixture(root)
            runbook = MODULE.build_runbook(
                project_root=root,
                generated_at="2026-07-25T00:00:00+00:00",
            )

        self.assertEqual(runbook["runtime"]["chromiumVersion"], "144.0.7559.132")
        self.assertRegex(runbook["runtime"]["archiveSHA256"], r"^[0-9a-f]{64}$")
        self.assertIn("not evidence by itself", runbook["releaseBoundary"])
        self.assertIn("fingerprint-audit.json", runbook["expectedFiles"])
        for key in (
            "inspectSpecificReport",
            "collectSpecificReport",
            "inspectNewestReport",
            "collectNewestReport",
        ):
            self.assertIn(
                "--runtime-lock runtime/fingerprint-chromium.lock.json",
                runbook["commands"][key],
            )

    def test_markdown_contains_finder_steps_and_collect_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_fixture(root)
            runbook = MODULE.build_runbook(project_root=root)
            markdown = MODULE.format_markdown(runbook)

        self.assertIn("Open Run-NeAntik-Runtime-Audit.command", markdown)
        self.assertIn("--collect", markdown)
        self.assertIn("verify-gui-fingerprint-report.py", markdown)
        self.assertIn("--runtime-lock runtime/fingerprint-chromium.lock.json", markdown)

    def test_missing_audit_kit_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "runtime").mkdir()
            (root / "runtime" / "fingerprint-chromium.lock.json").write_text(
                json.dumps(
                    {"fingerprintChromium": {"chromiumVersion": "144.0.7559.132"}}
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(MODULE.GuiAuditRunbookError, "archive is missing"):
                MODULE.build_runbook(project_root=root)


def write_fixture(root: Path) -> None:
    (root / "runtime").mkdir()
    (root / "dist").mkdir()
    (root / "runtime" / "fingerprint-chromium.lock.json").write_text(
        json.dumps({"fingerprintChromium": {"chromiumVersion": "144.0.7559.132"}}),
        encoding="utf-8",
    )
    (root / "dist" / "NeAntik-144.0.7559.132-source-branded-runtime-audit-kit.zip").write_bytes(
        b"fixture audit kit"
    )


if __name__ == "__main__":
    unittest.main()
