import importlib.util
import plistlib
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
    def make_runtime(self, root: Path) -> tuple[Path, dict[str, object]]:
        runtime = root / "NeAntik Browser.app"
        contents = runtime / "Contents"
        macos = contents / "MacOS"
        frameworks = contents / "Frameworks/Browser.framework/Versions/1"
        macos.mkdir(parents=True)
        frameworks.mkdir(parents=True)
        info = {
            "CFBundleExecutable": "NeAntik Browser",
            "CFBundleShortVersionString": "151.0.7922.75",
        }
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        (macos / "NeAntik Browser").write_bytes(b"real executable")
        framework = frameworks / "NeAntik Browser Framework"
        framework.write_bytes(b"real framework")
        report: dict[str, object] = {
            "executable": {
                "path": "Contents/MacOS/NeAntik Browser",
            },
            "framework": {
                "path": str(framework.relative_to(runtime)),
            },
        }
        return runtime, report

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

    def test_report_cannot_bind_alternate_in_prefix_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            runtime, report = self.make_runtime(Path(temporary))
            alternate = runtime / "Contents/MacOS/alternate"
            alternate.write_bytes(b"alternate")
            report["executable"] = {
                "path": "Contents/MacOS/alternate",
            }

            with self.assertRaisesRegex(
                MODULE.PackagedRuntimeReportError,
                "does not match CFBundleExecutable",
            ):
                MODULE.canonical_runtime_binaries(runtime, report)

    def test_report_cannot_bind_alternate_in_prefix_framework(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            runtime, report = self.make_runtime(Path(temporary))
            alternate = runtime / "Contents/Frameworks/alternate"
            alternate.write_bytes(b"alternate")
            report["framework"] = {
                "path": "Contents/Frameworks/alternate",
            }

            with self.assertRaisesRegex(
                MODULE.PackagedRuntimeReportError,
                "does not match the canonical Framework",
            ):
                MODULE.canonical_runtime_binaries(runtime, report)

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
