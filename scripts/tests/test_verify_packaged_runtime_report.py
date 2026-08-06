import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify-packaged-runtime-report.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_packaged_runtime_report",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VerifyPackagedRuntimeReportTests(unittest.TestCase):
    def test_canonical_bundle_path_rejects_escape(self) -> None:
        with self.assertRaisesRegex(
            MODULE.PackagedRuntimeReportError,
            "not canonical",
        ):
            MODULE.canonical_bundle_file(
                Path("/tmp/NeAntik Browser.app"),
                "Contents/MacOS/../../outside",
                "Contents/MacOS/",
            )

    def test_gpu_mode_requires_one_explicit_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "args.gn"
            path.write_text(
                "angle_enable_metal = true\nangle_enable_metal = false\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.PackagedRuntimeReportError,
                "exactly one Metal mode",
            ):
                MODULE.gpu_mode(path)

    def test_integrated_verifier_uses_packaged_evidence_mode(self) -> None:
        text = (
            ROOT / "scripts/verify-integrated-release.sh"
        ).read_text(encoding="utf-8")
        runtime_call = (
            '"$PROJECT_DIR/scripts/verify-built-runtime.sh" \\\n'
            '  "$RUNTIME_APP"'
        )

        self.assertIn(runtime_call, text)
        self.assertIn("verify-packaged-runtime-report.py", text)
        self.assertNotIn('REPORT="$(mktemp', text)
        self.assertNotIn('"$RUNTIME_APP" \\\n  "$REPORT"', text)
        self.assertNotIn("verify-runtime-report-consistency.py", text)


if __name__ == "__main__":
    unittest.main()
