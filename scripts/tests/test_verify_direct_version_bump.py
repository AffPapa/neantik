import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-direct-version-bump.py"
SPEC = importlib.util.spec_from_file_location("verify_direct_version_bump", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DirectVersionBumpTests(unittest.TestCase):
    def test_accepts_strictly_newer_version_and_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root, candidate=("0.3.12", "15"), published=("0.3.11", "14"))
            result = MODULE.verify(root)
            self.assertEqual(result["candidateVersion"], "0.3.12")

    def test_rejects_reused_version_or_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root, candidate=("0.3.11", "15"), published=("0.3.11", "14"))
            with self.assertRaisesRegex(MODULE.VersionBumpError, "must be newer"):
                MODULE.verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root, candidate=("0.3.12", "14"), published=("0.3.11", "14"))
            with self.assertRaisesRegex(MODULE.VersionBumpError, "must be greater"):
                MODULE.verify(root)

    def test_rejects_existing_candidate_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root, candidate=("0.3.12", "15"), published=("0.3.11", "14"))
            archive = root / "dist" / "NeAntik-0.3.12-arm64-notarized.zip"
            archive.parent.mkdir()
            archive.write_bytes(b"existing")
            with self.assertRaisesRegex(MODULE.VersionBumpError, "will not be overwritten"):
                MODULE.verify(root)

    def test_rejects_missing_release_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.12", "15"))
            with self.assertRaisesRegex(MODULE.VersionBumpError, "releases directory is missing"):
                MODULE.verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.12", "15"))
            (root / "releases").mkdir()
            with self.assertRaisesRegex(MODULE.VersionBumpError, "no checked-in release"):
                MODULE.verify(root)

    def test_rejects_malformed_release_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.12", "15"))
            release = root / "releases" / "v0.3.11.json"
            release.parent.mkdir()
            release.write_text('{"schemaVersion": 1,', encoding="utf-8")
            with self.assertRaisesRegex(MODULE.VersionBumpError, "malformed JSON"):
                MODULE.verify(root)

        malformed_contracts = (
            {"schemaVersion": 2, "tag": "v0.3.11", "version": "0.3.11", "build": 14},
            {"schemaVersion": 1, "tag": "v0.3.10", "version": "0.3.11", "build": 14},
            {"schemaVersion": 1, "tag": "v0.3.11", "version": "0.3.11", "build": True},
        )
        for contract in malformed_contracts:
            with self.subTest(contract=contract), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                write_candidate(root, ("0.3.12", "15"))
                write_release_contract(root, filename_version="0.3.11", metadata=contract)
                with self.assertRaises(MODULE.VersionBumpError):
                    MODULE.verify(root)

    def test_rejects_duplicate_release_versions_or_builds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.12", "16"))
            write_release(root, ("0.3.10", "14"))
            write_release_contract(
                root,
                filename_version="0.03.10",
                metadata={
                    "schemaVersion": 1,
                    "tag": "v0.03.10",
                    "version": "0.03.10",
                    "build": 15,
                },
            )
            with self.assertRaisesRegex(MODULE.VersionBumpError, "duplicate release version"):
                MODULE.verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.12", "16"))
            write_release(root, ("0.3.10", "14"))
            write_release(root, ("0.3.11", "14"))
            with self.assertRaisesRegex(MODULE.VersionBumpError, "duplicate release build"):
                MODULE.verify(root)

    def test_rejects_non_monotonic_release_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.12", "16"))
            write_release(root, ("0.3.10", "15"))
            write_release(root, ("0.3.11", "14"))
            with self.assertRaisesRegex(MODULE.VersionBumpError, "non-monotonic"):
                MODULE.verify(root)

    def test_uses_highest_valid_release_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.13", "17"))
            write_release(root, ("0.3.9", "14"))
            write_release(root, ("0.3.12", "16"))
            write_release(root, ("0.3.10", "15"))
            result = MODULE.verify(root)
            self.assertEqual(result["publishedVersion"], "0.3.12")
            self.assertEqual(result["publishedBuild"], 16)

    def test_git_repo_ignores_untracked_release_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_candidate(root, ("0.3.12", "16"))
            write_release(root, ("0.3.10", "14"))
            subprocess.run(
                ["git", "init", "-q", str(root)],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "add",
                    "releases/v0.3.10.json",
                ],
                check=True,
            )
            write_release(root, ("0.3.11", "15"))

            result = MODULE.verify(root)

            self.assertEqual(result["publishedVersion"], "0.3.10")
            self.assertEqual(result["publishedBuild"], 14)


def write_project(
    root: Path,
    *,
    candidate: tuple[str, str],
    published: tuple[str, str],
) -> None:
    write_candidate(root, candidate)
    write_release(root, published)


def write_candidate(root: Path, candidate: tuple[str, str]) -> None:
    info = root / "Resources" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleShortVersionString": candidate[0],
                "CFBundleVersion": candidate[1],
            },
            file,
        )


def write_release(root: Path, published: tuple[str, str]) -> None:
    version, build = published
    write_release_contract(
        root,
        filename_version=version,
        metadata={
            "schemaVersion": 1,
            "tag": f"v{version}",
            "version": version,
            "build": int(build),
        },
    )


def write_release_contract(
    root: Path,
    *,
    filename_version: str,
    metadata: dict[str, object],
) -> None:
    release = root / "releases" / f"v{filename_version}.json"
    release.parent.mkdir(parents=True, exist_ok=True)
    release.write_text(json.dumps(metadata), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
