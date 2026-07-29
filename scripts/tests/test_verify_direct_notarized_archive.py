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

EXPECTED = MODULE.ExpectedAppContract(
    bundle_identifier="app.neantik.desktop",
    version="1.2.3",
    build="7",
    team_identifier="H6VGU2M6JD",
)


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
            "Identifier=app.neantik.desktop\n"
            "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
            "Authority=Developer ID Application: Example (H6VGU2M6JD)\n"
            "Timestamp=Jul 25, 2026 at 12:00:00\n"
            "TeamIdentifier=H6VGU2M6JD\n",
            expected=EXPECTED,
        )
        with self.assertRaisesRegex(MODULE.DirectNotarizedArchiveError, "Developer ID"):
            MODULE.parse_codesign_display(
                "Identifier=app.neantik.desktop\n"
                "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
                "Authority=Apple Development: Example\n"
                "Timestamp=Jul 25, 2026 at 12:00:00\n"
                "TeamIdentifier=H6VGU2M6JD\n",
                expected=EXPECTED,
            )

    def test_rejects_wrong_bundle_identifier(self) -> None:
        with self.assertRaisesRegex(
            MODULE.DirectNotarizedArchiveError,
            "signature identifier",
        ):
            MODULE.parse_codesign_display(
                signed_display(identifier="com.example.other"),
                expected=EXPECTED,
            )

    def test_rejects_wrong_team_identifier(self) -> None:
        with self.assertRaisesRegex(
            MODULE.DirectNotarizedArchiveError,
            "expected Developer ID Application team",
        ):
            MODULE.parse_codesign_display(
                signed_display(team_identifier="ATTACKER1"),
                expected=EXPECTED,
            )

    def test_rejects_wrong_version_or_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            write_app_info(app, version="9.9.9", build="999")
            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "CFBundleShortVersionString",
            ):
                MODULE.verify_app_contract(app, expected=EXPECTED)

    def test_verify_app_runs_codesign_stapler_and_spctl(self) -> None:
        commands: list[list[str]] = []

        def runner(command):
            commands.append(command)
            if command[:2] == ["codesign", "--display"]:
                return MODULE.CommandResult(
                    0,
                    signed_display(),
                )
            return MODULE.CommandResult(0, "ok")

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            write_app_info(app)
            MODULE.verify_app(app, expected=EXPECTED, runner=runner)

        joined = [" ".join(command[:3]) for command in commands]
        self.assertIn("xcrun stapler validate", joined)
        self.assertIn("spctl --assess --type", joined)

    def test_verify_app_fails_closed_when_stapler_or_spctl_fails(self) -> None:
        def runner(command):
            if command[:2] == ["codesign", "--display"]:
                return MODULE.CommandResult(
                    0,
                    signed_display(),
                )
            if command[:3] == ["xcrun", "stapler", "validate"]:
                return MODULE.CommandResult(66, "LSDataUnavailable")
            return MODULE.CommandResult(0, "ok")

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            write_app_info(app)
            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "stapler validate",
            ):
                MODULE.verify_app(app, expected=EXPECTED, runner=runner)

        def spctl_runner(command):
            if command[:2] == ["codesign", "--display"]:
                return MODULE.CommandResult(
                    0,
                    signed_display(),
                )
            if command[:2] == ["spctl", "--assess"]:
                return MODULE.CommandResult(1, "assessment failed")
            return MODULE.CommandResult(0, "ok")

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "NeAntik.app"
            write_app_info(app)
            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "spctl --assess",
            ):
                MODULE.verify_app(app, expected=EXPECTED, runner=spctl_runner)

    def test_archive_runs_integrated_provenance_verifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_info(root, version="1.2.3")
            archive = write_archive(root)
            commands: list[list[str]] = []

            def runner(command):
                commands.append(command)
                if command[:4] == ["ditto", "-x", "-k", str(archive)]:
                    write_app_info(Path(command[4]) / "NeAntik.app")
                if command[:2] == ["codesign", "--display"]:
                    return MODULE.CommandResult(0, signed_display())
                return MODULE.CommandResult(0, "ok")

            MODULE.verify_archive(
                archive=archive,
                project_root=root,
                runner=runner,
            )

            self.assertTrue(
                any(
                    command[0].endswith(
                        "scripts/verify-integrated-release.sh"
                    )
                    for command in commands
                )
            )

    def test_rejects_stale_or_missing_runtime_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_info(root, version="1.2.3")
            archive = write_archive(root)

            def runner(command):
                if command[:4] == ["ditto", "-x", "-k", str(archive)]:
                    write_app_info(Path(command[4]) / "NeAntik.app")
                if command[:2] == ["codesign", "--display"]:
                    return MODULE.CommandResult(0, signed_display())
                if command[0].endswith(
                    "scripts/verify-integrated-release.sh"
                ):
                    return MODULE.CommandResult(
                        65,
                        "Integrated NeAntik patch series does not match",
                    )
                return MODULE.CommandResult(0, "ok")

            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "patch series does not match",
            ):
                MODULE.verify_archive(
                    archive=archive,
                    project_root=root,
                    runner=runner,
                )

    def test_extract_requires_clean_public_app_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "NeAntik-Integrated.app").mkdir()
            with self.assertRaisesRegex(
                MODULE.DirectNotarizedArchiveError,
                "NeAntik.app",
            ):
                MODULE.find_single_app(root)


def signed_display(
    *,
    identifier: str = "app.neantik.desktop",
    team_identifier: str = "H6VGU2M6JD",
) -> str:
    return (
        f"Identifier={identifier}\n"
        "CodeDirectory v=20500 size=123 flags=0x10000(runtime)\n"
        f"Authority=Developer ID Application: Example ({team_identifier})\n"
        "Authority=Developer ID Certification Authority\n"
        "Authority=Apple Root CA\n"
        "Timestamp=Jul 25, 2026 at 12:00:00\n"
        f"TeamIdentifier={team_identifier}\n"
    )


def write_info(
    root: Path,
    *,
    version: str,
    build: str = "7",
    team_identifier: str = "H6VGU2M6JD",
) -> None:
    info = root / "Resources" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleIdentifier": "app.neantik.desktop",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
                "NeAntikDeveloperTeamIdentifier": team_identifier,
            },
            file,
        )


def write_app_info(
    app: Path,
    *,
    version: str = "1.2.3",
    build: str = "7",
) -> None:
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleIdentifier": "app.neantik.desktop",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
                "NeAntikDeveloperTeamIdentifier": "H6VGU2M6JD",
            },
            file,
        )


def write_archive(root: Path) -> Path:
    archive = root / "dist" / "NeAntik-1.2.3-arm64-notarized.zip"
    archive.parent.mkdir(parents=True)
    with zipfile.ZipFile(archive, "w") as zip_file:
        zip_file.writestr(
            "NeAntik.app/Contents/MacOS/NeAntik",
            "placeholder",
        )
    checksum = MODULE.sha256_file(archive)
    archive.with_suffix(".zip.sha256").write_text(
        f"{checksum}  {archive.name}\n",
        encoding="utf-8",
    )
    return archive


if __name__ == "__main__":
    unittest.main()
