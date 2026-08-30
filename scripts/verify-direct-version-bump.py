#!/usr/bin/env python3
from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RELEASE_FILENAME = re.compile(r"^v(?P<version>\d+(?:\.\d+){2})\.json$")


class VersionBumpError(ValueError):
    pass


@dataclass(frozen=True)
class PublishedRelease:
    version: str
    build: int
    source: Path


def version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(?:\.\d+){2}", value):
        raise VersionBumpError(f"invalid semantic version: {value}")
    return tuple(int(part) for part in value.split("."))


def read_candidate(project_root: Path) -> tuple[str, int]:
    with (project_root / "Resources" / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    return str(info["CFBundleShortVersionString"]), int(info["CFBundleVersion"])


def read_release_contract(path: Path) -> PublishedRelease:
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError) as error:
        raise VersionBumpError(
            f"release contract {path.name} is malformed JSON"
        ) from error
    if not isinstance(metadata, dict):
        raise VersionBumpError(
            f"release contract {path.name} must contain a JSON object"
        )

    filename_match = RELEASE_FILENAME.fullmatch(path.name)
    if not filename_match:
        raise VersionBumpError(f"invalid release contract filename: {path.name}")
    filename_version = filename_match.group("version")

    schema_version = metadata.get("schemaVersion")
    version = metadata.get("version")
    tag = metadata.get("tag")
    build = metadata.get("build")
    if schema_version != 1:
        raise VersionBumpError(
            f"release contract {path.name} has unsupported schemaVersion"
        )
    if not isinstance(version, str):
        raise VersionBumpError(
            f"release contract {path.name} has invalid version"
        )
    version_tuple(version)
    if version != filename_version:
        raise VersionBumpError(
            f"release contract {path.name} version does not match its filename"
        )
    if tag != f"v{version}":
        raise VersionBumpError(
            f"release contract {path.name} tag does not match its version"
        )
    if isinstance(build, bool) or not isinstance(build, int) or build <= 0:
        raise VersionBumpError(
            f"release contract {path.name} has invalid build"
        )
    return PublishedRelease(version=version, build=build, source=path)


def read_published(project_root: Path) -> tuple[str, int]:
    releases_root = project_root / "releases"
    if not releases_root.is_dir():
        raise VersionBumpError("releases directory is missing")

    contract_paths = checked_in_release_contracts(project_root)
    if not contract_paths:
        raise VersionBumpError("no checked-in release contracts found")

    releases = [read_release_contract(path) for path in contract_paths]
    versions: set[tuple[int, ...]] = set()
    builds: set[int] = set()
    for release in releases:
        parsed_version = version_tuple(release.version)
        if parsed_version in versions:
            raise VersionBumpError(
                f"duplicate release version: {release.version}"
            )
        if release.build in builds:
            raise VersionBumpError(f"duplicate release build: {release.build}")
        versions.add(parsed_version)
        builds.add(release.build)

    ordered = sorted(releases, key=lambda release: version_tuple(release.version))
    for previous, current in zip(ordered, ordered[1:]):
        if current.build <= previous.build:
            raise VersionBumpError(
                "release contracts are non-monotonic: "
                f"{current.version} build {current.build} must be greater than "
                f"{previous.version} build {previous.build}"
            )
    latest = ordered[-1]
    return latest.version, latest.build


def checked_in_release_contracts(project_root: Path) -> list[Path]:
    """Return release contracts tracked by Git, or fixture files outside Git."""
    if (project_root / ".git").exists():
        result = subprocess.run(
            [
                "git",
                "-C",
                str(project_root),
                "ls-files",
                "--",
                "releases/v*.json",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return sorted(
            project_root / relative
            for relative in result.stdout.splitlines()
            if relative
        )
    return sorted((project_root / "releases").glob("v*.json"))


def verify(project_root: Path = PROJECT_ROOT) -> dict[str, object]:
    candidate_version, candidate_build = read_candidate(project_root)
    published_version, published_build = read_published(project_root)
    if version_tuple(candidate_version) <= version_tuple(published_version):
        raise VersionBumpError(
            f"candidate version {candidate_version} must be newer than "
            f"published {published_version}"
        )
    if candidate_build <= published_build:
        raise VersionBumpError(
            f"candidate build {candidate_build} must be greater than "
            f"published {published_build}"
        )
    archive = (
        project_root
        / "dist"
        / f"NeAntik-{candidate_version}-arm64-notarized.zip"
    )
    sidecar = archive.with_suffix(".zip.sha256")
    if archive.exists() or sidecar.exists():
        raise VersionBumpError(
            "candidate archive or checksum already exists; release output "
            "will not be overwritten"
        )
    return {
        "candidateVersion": candidate_version,
        "candidateBuild": candidate_build,
        "publishedVersion": published_version,
        "publishedBuild": published_build,
    }


def main() -> int:
    try:
        result = verify()
    except (OSError, VersionBumpError) as error:
        print(f"Direct version bump verification failed: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: Direct candidate "
        f"{result['candidateVersion']} ({result['candidateBuild']}) is newer "
        f"than published {result['publishedVersion']} "
        f"({result['publishedBuild']})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
