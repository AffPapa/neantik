#!/usr/bin/env python3
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RELEASE_BLOCK = re.compile(
    r"export const latestRelease = \{(?P<body>.*?)\} as const;",
    re.DOTALL,
)
FIELD = re.compile(r'^\s*(?P<key>\w+):\s*"(?P<value>[^"]+)"', re.MULTILINE)


class VersionBumpError(ValueError):
    pass


def version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(?:\.\d+){2}", value):
        raise VersionBumpError(f"invalid semantic version: {value}")
    return tuple(int(part) for part in value.split("."))


def read_candidate(project_root: Path) -> tuple[str, int]:
    with (project_root / "Resources" / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    return str(info["CFBundleShortVersionString"]), int(info["CFBundleVersion"])


def read_published(project_root: Path) -> tuple[str, int]:
    text = (
        project_root / "TelemetryDashboard" / "content" / "release.ts"
    ).read_text(encoding="utf-8")
    match = RELEASE_BLOCK.search(text)
    if not match:
        raise VersionBumpError("latestRelease block is missing")
    fields = {
        item.group("key"): item.group("value")
        for item in FIELD.finditer(match.group("body"))
    }
    try:
        return fields["version"], int(fields["build"])
    except (KeyError, ValueError) as error:
        raise VersionBumpError(
            "latestRelease version/build is invalid"
        ) from error


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
