import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "export-gui-fingerprint-readiness-report.py"
SPEC = importlib.util.spec_from_file_location("export_gui_fingerprint_readiness_report", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write_runtime_fixture(root: Path) -> None:
    (root / "runtime").mkdir(parents=True)
    (root / "dist").mkdir(parents=True)
    (root / "runtime" / "fingerprint-chromium.lock.json").write_text(
        json.dumps({"fingerprintChromium": {"chromiumVersion": "144.0.7559.132"}}),
        encoding="utf-8",
    )
    (root / "dist" / "NeAntik-144.0.7559.132-source-branded-runtime-audit-kit.zip").write_bytes(
        b"runtime-audit-kit"
    )


def passing_verifier(*, project_root, report_path, runtime_lock):
    return {
        "command": ["python3", "scripts/verify-gui-fingerprint-report.py", str(report_path)],
        "passed": True,
        "returnCode": 0,
        "outputPreview": ["PASS"],
    }


class GuiFingerprintReadinessReportExporterTests(unittest.TestCase):
    def test_exports_missing_report_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_runtime_fixture(root)
            report = MODULE.build_report(
                project_root=root,
                generated_at="2026-07-26T00:00:00+00:00",
            )

        self.assertFalse(report["ready"])
        self.assertFalse(report["report"]["exists"])
        self.assertEqual(report["blockedGates"], ["Production GUI fingerprint report"])
        self.assertIn("does not launch", report["releaseBoundary"])
        template = report["ownerEvidenceInputTemplate"]
        self.assertEqual(template["target"], "dist/fingerprint-audit.json")
        self.assertEqual(template["placeholdersMustBeReplaced"], MODULE.OWNER_EVIDENCE_PLACEHOLDERS)
        self.assertEqual(template["collectContract"]["requiredExecutionMode"], "browser")
        self.assertTrue(any("Do not invent" in item for item in template["safetyBoundary"]))
        self.assertTrue(
            any("Run-NeAntik-Runtime-Audit.command" in action for action in report["nextOwnerActions"])
        )

    def test_exports_ready_when_report_verifies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_runtime_fixture(root)
            fingerprint_report = root / "dist" / "fingerprint-audit.json"
            fingerprint_report.write_text("{}", encoding="utf-8")
            report = MODULE.build_report(
                project_root=root,
                report_path=fingerprint_report,
                generated_at="2026-07-26T00:00:00+00:00",
                verifier=passing_verifier,
            )

        self.assertTrue(report["ready"])
        self.assertTrue(report["report"]["exists"])
        self.assertEqual(report["blockedGates"], [])
        self.assertTrue(report["verification"]["passed"])

    def test_writes_json_and_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_runtime_fixture(root)
            report = MODULE.build_report(
                project_root=root,
                generated_at="2026-07-26T00:00:00+00:00",
            )
            output = root / "dist" / "GUI-FINGERPRINT-READINESS.json"
            markdown = root / "dist" / "GUI-FINGERPRINT-READINESS.md"
            MODULE.write_outputs(report, output=output, markdown=markdown)
            saved = json.loads(output.read_text(encoding="utf-8"))
            text = markdown.read_text(encoding="utf-8")

        self.assertEqual(saved["mode"], "direct-gui-fingerprint-readiness-snapshot")
        self.assertIn("# NeAntik GUI fingerprint readiness snapshot", text)
        self.assertIn("## Owner evidence input template", text)
        self.assertIn("<ABSOLUTE_GUI_FINGERPRINT_AUDIT_JSON>", text)
        self.assertIn("Production GUI fingerprint report", text)


if __name__ == "__main__":
    unittest.main()
