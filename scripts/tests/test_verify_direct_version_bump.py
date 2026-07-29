import importlib.util
import plistlib
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


def write_project(
    root: Path,
    *,
    candidate: tuple[str, str],
    published: tuple[str, str],
) -> None:
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
    release = root / "TelemetryDashboard" / "content" / "release.ts"
    release.parent.mkdir(parents=True)
    release.write_text(
        f'''export const latestRelease = {{
  version: "{published[0]}",
  build: "{published[1]}",
}} as const;
''',
        encoding="utf-8",
    )


if __name__ == "__main__":
    unittest.main()
