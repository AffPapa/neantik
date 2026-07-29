import importlib.util
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-direct-notarized-archive.py"
SPEC = importlib.util.spec_from_file_location("verify_direct_notarized_archive", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DirectNotarizedArchiveVerifierTests(unittest.TestCase):
    def test_archive_contract_accepts_matching_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_info(root, version="1.2.3")
            archive = root / "dist" / "NeAntik-1.2.3-arm64-notarized.zip"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"zip")
            checksum = MODULE.sha256_file(archive)
            archive.with_suffix(".zip.sha256").write_text(f"{checksum}  {archive.name}\n", encoding="utf-8")

            self.assertEqual(
                MODULE.assert_archive_contract(archive, project_root=root),
                checksum,
            )

    def test_archive_contract_rejects_engineering_archive_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_info(root, version="1.2.3")
            archive = root / "dist" / "NeAntik-1.2.3-arm64-metal-integrated.zip"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"zip")
            archive.with_suffix(".zip.sha256").write_text("0\n", encoding="utf-8")

            with self.assertRaisesRegex(MODULE.DirectNotarizedArchiveError, "archive name"):
                MODULE.assert_archive_contract(archive, project_root=root)

    def test_rejects_finder_metadata_in_zip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("NeAntik.app/Contents/MacOS/NeAntik", "binary")
                zip_file.writestr("__MACOSX/._NeAntik.app", "metadata")

            with self.assertRaisesRegex(MODULE.DirectNotarizedArchiveError, "Finder metadata"):
                MODULE.assert_zip_has_no_finder_metadata(archive)

    def test_codesign_display_requires_developer_id_runtime_and_timestamp(self) -> None:
        MODULE.parse_codesign_display(
            "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
            "Authority=Developer ID Application: Example (TEAMID)\n"
            "Timestamp=Jul 25, 2026 at 12:00:00\n"
        )
        with self.assertRaisesRegex(MODULE.DirectNotarizedArchiveError, "Developer ID"):
            MODULE.parse_codesign_display(
                "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
                "Authority=Apple Development: Example\n"
                "Timestamp=Jul 25, 2026 at 12:00:00\n"
            )

    def test_verify_app_runs_codesign_stapler_and_spctl(self) -> None:
        commands: list[list[str]] = []

        def runner(command):
            commands.append(command)
            if command[:2] == ["codesign", "--display"]:
                return MODULE.CommandResult(
                    0,
                    "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
                    "Authority=Developer ID Application: Example (TEAMID)\n"
                    "Timestamp=Jul 25, 2026 at 12:00:00\n",
                )
            return MODULE.CommandResult(0, "ok")

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            app.mkdir()
            MODULE.verify_app(app, runner=runner)

        joined = [" ".join(command[:3]) for command in commands]
        self.assertIn("xcrun stapler validate", joined)
        self.assertIn("spctl --assess --type", joined)

    def test_verify_app_fails_closed_when_stapler_or_spctl_fails(self) -> None:
        def runner(command):
            if command[:2] == ["codesign", "--display"]:
                return MODULE.CommandResult(
                    0,
                    "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
                    "Authority=Developer ID Application: Example (TEAMID)\n"
                    "Timestamp=Jul 25, 2026 at 12:00:00\n"
                    "Notarization Ticket=stapled\n",
                )
            if command[:3] == ["xcrun", "stapler", "validate"]:
                return MODULE.CommandResult(66, "LSDataUnavailable")
            return MODULE.CommandResult(0, "ok")

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            app.mkdir()
            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "stapler validate",
            ):
                MODULE.verify_app(app, runner=runner)

        def spctl_runner(command):
            if command[:2] == ["codesign", "--display"]:
                return MODULE.CommandResult(
                    0,
                    "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
                    "Authority=Developer ID Application: Example (TEAMID)\n"
                    "Timestamp=Jul 25, 2026 at 12:00:00\n"
                    "Notarization Ticket=stapled\n",
                )
            if command[:2] == ["spctl", "--assess"]:
                return MODULE.CommandResult(1, "assessment failed")
            return MODULE.CommandResult(0, "ok")

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            app.mkdir()
            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "spctl --assess",
            ):
                MODULE.verify_app(app, runner=spctl_runner)

    def test_extract_requires_clean_public_app_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "NeAntik-Integrated.app").mkdir()
            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "NeAntik.app",
            ):
                MODULE.find_single_app(root)


def write_info(root: Path, *, version: str) -> None:
    info = root / "Resources" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as file:
        plistlib.dump({"CFBundleShortVersionString": version}, file)


if __name__ == "__main__":
    unittest.main()
