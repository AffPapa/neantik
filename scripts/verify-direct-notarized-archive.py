#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class DirectNotarizedArchiveError(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    output: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_info_version(project_root: Path) -> str:
    with (project_root / "Resources" / "Info.plist").open("rb") as file:
        return str(plistlib.load(file)["CFBundleShortVersionString"])


def expected_archive(project_root: Path) -> Path:
    version = read_info_version(project_root)
    return project_root / "dist" / f"NeAntik-{version}-arm64-notarized.zip"


def assert_archive_contract(archive: Path, *, project_root: Path) -> str:
    expected = expected_archive(project_root)
    if archive.name != expected.name:
        raise DirectNotarizedArchiveError(
            f"archive name must be {expected.name}, got {archive.name}"
        )
    if not archive.is_file():
        raise DirectNotarizedArchiveError(f"archive is missing: {archive}")
    checksum = archive.with_suffix(archive.suffix + ".sha256")
    if not checksum.is_file():
        raise DirectNotarizedArchiveError(f"checksum sidecar is missing: {checksum}")
    recorded = checksum.read_text(encoding="utf-8").split()
    if not recorded:
        raise DirectNotarizedArchiveError(f"checksum sidecar is empty: {checksum}")
    actual = sha256_file(archive)
    if recorded[0] != actual:
        raise DirectNotarizedArchiveError(
            f"checksum mismatch for {archive.name}: sidecar={recorded[0]} actual={actual}"
        )
    return actual


def assert_zip_has_no_finder_metadata(archive: Path) -> None:
    forbidden: list[str] = []
    with zipfile.ZipFile(archive) as zip_file:
        for name in zip_file.namelist():
            parts = name.split("/")
            basename = parts[-1]
            if "__MACOSX" in parts or basename == ".DS_Store" or basename.startswith("._"):
                forbidden.append(name)
    if forbidden:
        raise DirectNotarizedArchiveError(
            "archive contains Finder metadata: " + ", ".join(forbidden[:5])
        )


def default_runner(command: list[str]) -> CommandResult:
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return CommandResult(completed.returncode, completed.stdout.strip())


def run_checked(command: list[str], runner=default_runner) -> str:
    result = runner(command)
    if result.returncode != 0:
        raise DirectNotarizedArchiveError(
            f"command failed: {' '.join(command)}\n{result.output}"
        )
    return result.output


def parse_codesign_display(output: str) -> None:
    if not re.search(r"(?m)^CodeDirectory .*flags=.*runtime", output):
        raise DirectNotarizedArchiveError("Developer ID app is missing hardened runtime flag")
    if not re.search(r"(?m)^Authority=Developer ID Application:", output):
        raise DirectNotarizedArchiveError("app is not signed by Developer ID Application")
    if not re.search(r"(?m)^Timestamp=", output):
        raise DirectNotarizedArchiveError("app signature is missing trusted timestamp")


def find_single_app(root: Path) -> Path:
    apps = [path for path in root.rglob("*.app") if path.is_dir()]
    top_level = [path for path in apps if path.parent == root]
    if len(top_level) != 1:
        raise DirectNotarizedArchiveError(
            f"expected exactly one top-level .app in archive, found {len(top_level)}"
        )
    if top_level[0].name != "NeAntik.app":
        raise DirectNotarizedArchiveError(
            "top-level application must be named NeAntik.app, "
            f"got {top_level[0].name}"
        )
    return top_level[0]


def extract_archive(archive: Path, destination: Path, runner=default_runner) -> Path:
    run_checked(["ditto", "-x", "-k", str(archive), str(destination)], runner=runner)
    return find_single_app(destination)


def verify_app(app: Path, runner=default_runner) -> None:
    display = run_checked(["codesign", "--display", "--verbose=4", str(app)], runner=runner)
    parse_codesign_display(display)
    run_checked(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], runner=runner)
    run_checked(
        ["xcrun", "stapler", "validate", str(app)],
        runner=runner,
    )
    run_checked(
        ["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)],
        runner=runner,
    )


def verify_archive(
    *,
    archive: Path,
    project_root: Path = PROJECT_ROOT,
    runner=default_runner,
) -> dict[str, str]:
    checksum = assert_archive_contract(archive, project_root=project_root)
    assert_zip_has_no_finder_metadata(archive)
    with tempfile.TemporaryDirectory(prefix="nevision-notarized-verify-") as temporary:
        app = extract_archive(archive, Path(temporary), runner=runner)
        verify_app(app, runner=runner)
    return {
        "archive": str(archive),
        "sha256": checksum,
        "status": "notarized-archive-verified",
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify a public NeAntik Direct notarized archive after release-direct.sh.",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    archive = (args.archive or expected_archive(project_root)).resolve()
    try:
        result = verify_archive(archive=archive, project_root=project_root)
    except (OSError, zipfile.BadZipFile, DirectNotarizedArchiveError) as error:
        print(f"Direct notarized archive verification failed: {error}", file=sys.stderr)
        return 1
    print("PASS: Direct notarized archive verified.")
    print(f"Archive: {result['archive']}")
    print(f"SHA-256: {result['sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
