import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-runtime-security-reference.py"
SPEC = importlib.util.spec_from_file_location("verify_runtime_security_reference", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class RuntimeSecurityReferenceTests(unittest.TestCase):
    def test_accepts_official_desktop_security_post_containing_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(Path(temporary))
            message = MODULE.verify_reference(
                baseline_path=baseline,
                html_text=(
                    "<title>Stable Channel Update for Desktop</title>"
                    "The Stable channel has been updated to 150.0.7871.186/.187 "
                    "for Windows and Mac. This update includes 4 security fixes."
                ),
            )

        self.assertIn("reference verified", message)
        self.assertIn("security fixes 4", message)

    def test_accepts_official_desktop_post_without_enumerated_fixes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(Path(temporary))
            data = json.loads(baseline.read_text(encoding="utf-8"))
            data["minimumPublicChromiumVersion"] = "151.0.7922.75"
            data["alsoObservedPublicChromiumVersions"] = ["151.0.7922.76"]
            data["securityFixCount"] = 0
            baseline.write_text(json.dumps(data), encoding="utf-8")
            message = MODULE.verify_reference(
                baseline_path=baseline,
                html_text=(
                    "<title>Stable Channel Update for Desktop</title>"
                    "The Stable channel has been updated to "
                    "151.0.7922.75/.76 for Windows and Mac."
                ),
            )

        self.assertIn("reference verified", message)
        self.assertIn("security fixes not enumerated", message)

    def test_rejects_non_official_reference_host(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(
                Path(temporary),
                reference="https://example.test/chrome-release",
            )
            with self.assertRaisesRegex(MODULE.SecurityReferenceError, "chromereleases"):
                MODULE.verify_reference(baseline_path=baseline, html_text=valid_html())

    def test_rejects_reference_without_baseline_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(Path(temporary))
            with self.assertRaisesRegex(MODULE.SecurityReferenceError, "not found"):
                MODULE.verify_reference(
                    baseline_path=baseline,
                    html_text=(
                        "<title>Stable Channel Update for Desktop</title>"
                        "Chrome 151.0.1.2 Mac 4 security fixes."
                    ),
                )

    def test_rejects_non_desktop_stable_page(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(Path(temporary))
            with self.assertRaisesRegex(MODULE.SecurityReferenceError, "desktop Stable"):
                MODULE.verify_reference(
                    baseline_path=baseline,
                    html_text="Chrome 150.0.7871.186 150.0.7871.187 Mac 4 security fixes.",
                )

    def test_rejects_reference_without_observed_mac_patch_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(Path(temporary))
            with self.assertRaisesRegex(MODULE.SecurityReferenceError, "Observed public version"):
                MODULE.verify_reference(
                    baseline_path=baseline,
                    html_text=(
                        "<title>Stable Channel Update for Desktop</title>"
                        "Chrome 150.0.7871.186 Mac 4 security fixes."
                    ),
                )

    def test_rejects_reference_without_security_fix_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(Path(temporary))
            with self.assertRaisesRegex(MODULE.SecurityReferenceError, "securityFixCount"):
                MODULE.verify_reference(
                    baseline_path=baseline,
                    html_text=(
                        "<title>Stable Channel Update for Desktop</title>"
                        "Chrome 150.0.7871.186 150.0.7871.187 Mac security fixes."
                    ),
                )

    def test_rejects_missing_baseline_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            baseline = write_baseline(Path(temporary))
            data = json.loads(baseline.read_text(encoding="utf-8"))
            del data["releaseBoundary"]
            baseline.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.SecurityReferenceError, "releaseBoundary"):
                MODULE.verify_reference(baseline_path=baseline, html_text=valid_html())


def write_baseline(
    root: Path,
    *,
    reference: str = (
        "https://chromereleases.googleblog.com/2026/07/"
        "stable-channel-update-for-desktop_01320465736.html"
    ),
) -> Path:
    path = root / "baseline.json"
    path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "checkedAt": "2026-07-25",
                "publishedAt": "2026-07-23",
                "maximumAgeDays": 7,
                "minimumPublicChromiumVersion": "150.0.7871.186",
                "alsoObservedPublicChromiumVersions": ["150.0.7871.187"],
                "channel": "Desktop Stable",
                "platforms": ["macOS"],
                "securityFixCount": 4,
                "reference": reference,
                "referenceTitle": "Stable Channel Update for Desktop",
                "sourceLabel": "Chrome Releases",
                "releaseBoundary": "This is a manually pinned primary-source security baseline. It is not a live updater. Refresh checkedAt, versions, securityFixCount and reference before every public Direct release.",
            }
        ),
        encoding="utf-8",
    )
    return path


def valid_html() -> str:
    return (
        "<title>Stable Channel Update for Desktop</title>"
        "Chrome 150.0.7871.186 150.0.7871.187 Mac 4 security fixes."
    )


if __name__ == "__main__":
    unittest.main()
