#!/usr/bin/env python3
"""Create one deterministic AffPapa snapshot from verified Direct artifacts.

This command only prepares local metadata and copies already-built artifacts.
`scripts/neantik-affpapa-release prepare` remains responsible for repeating
signature, notarization, Gatekeeper and server-side validation before upload.

The release source and the release tooling are two separate inputs. Release
tooling is the checked-out worktree that runs this script, and it may legally
be newer than the release it publishes. Release source is the immutable
commit the published binaries were built from. When `--release-tag` and
`--release-commit` are given, every product fact written into the snapshot
(version, build, changelog, runtime) is read out of that exact commit with
`git show`, never out of the newer worktree, and the pinned pair is confirmed
against the GitHub tag, the immutable release flag and per-asset release
attestations before anything is written.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
HEADING_RE = re.compile(
    r"^## Direct (?P<version>\d+\.\d+\.\d+) "
    r"\((?P<build>\d+)\)\s+—"
)
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
GITHUB_REPO = "AffPapa/neantik"
RUSSIAN_MONTHS = (
    "января",
    "февраля",
    "марта",
    "апреля",
    "мая",
    "июня",
    "июля",
    "августа",
    "сентября",
    "октября",
    "ноября",
    "декабря",
)


class SnapshotError(ValueError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SnapshotError(f"JSON root must be an object: {path}")
    return value


def regular_file(path: Path) -> Path:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise SnapshotError(f"Required file is missing: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise SnapshotError(f"Required input must be a regular file: {path}")
    return path


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def russian_display_date(value: dt.date) -> str:
    return f"{value.day} {RUSSIAN_MONTHS[value.month - 1]} {value.year}"


def parse_version(data: bytes) -> tuple[str, int]:
    info = plistlib.loads(data)
    return str(info["CFBundleShortVersionString"]), int(info["CFBundleVersion"])


def read_version(project_root: Path) -> tuple[str, int]:
    return parse_version((project_root / "Resources/Info.plist").read_bytes())


def read_release_notes(
    changelog: Path, version: str, build: int
) -> list[str]:
    return parse_release_notes(
        changelog.read_text(encoding="utf-8"), version, build
    )


def parse_release_notes(changelog: str, version: str, build: int) -> list[str]:
    lines = changelog.splitlines()
    active = False
    items: list[str] = []
    current: list[str] = []
    for line in lines:
        heading = HEADING_RE.match(line)
        if heading:
            if active:
                break
            active = (
                heading.group("version") == version
                and int(heading.group("build")) == build
            )
            continue
        if not active:
            continue
        if line.startswith("- "):
            if current:
                items.append(" ".join(current))
            current = [line[2:].strip()]
        elif current and (line.startswith("  ") or not line.strip()):
            if line.strip():
                current.append(line.strip())
        elif line.startswith("## "):
            break
    if current:
        items.append(" ".join(current))
    if not items:
        raise SnapshotError(
            f"CHANGELOG has no notes for Direct {version} ({build})"
        )
    return items


def git_commit(project_root: Path) -> str:
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=project_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    if status:
        raise SnapshotError("Release snapshot requires a clean Git worktree")
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=project_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()
    if not COMMIT_RE.fullmatch(commit):
        raise SnapshotError("Git HEAD is not a canonical commit")
    return commit


def read_source_bytes(project_root: Path, commit: str, relative: str) -> bytes:
    """Read one tracked file out of the pinned release commit."""
    result = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=project_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise SnapshotError(
            f"Release source {commit}:{relative} is unavailable: "
            f"{result.stderr.decode('utf-8', 'replace').strip()}"
        )
    return result.stdout


def gh_output(arguments: list[str]) -> str:
    result = subprocess.run(
        ["gh", *arguments],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise SnapshotError(
            f"GitHub CLI call failed: gh {' '.join(arguments)}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout


def verify_release_source(
    project_root: Path,
    tag: str,
    commit: str,
    artifacts: tuple[Path, ...],
) -> None:
    """Bind the pinned release source to the immutable GitHub release.

    The release tooling commit is deliberately not consulted here: a newer
    tooling commit must never be able to relabel which source a published
    snapshot points at.
    """
    if not TAG_RE.fullmatch(tag):
        raise SnapshotError(f"Release tag must be vSEMVER, got {tag!r}")
    if not COMMIT_RE.fullmatch(commit):
        raise SnapshotError(
            "Release commit must be 40 lowercase hexadecimal characters"
        )
    present = subprocess.run(
        ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
        cwd=project_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if present.returncode != 0:
        raise SnapshotError(f"Release commit is not available locally: {commit}")
    resolved = gh_output(
        ["api", f"repos/{GITHUB_REPO}/commits/{tag}", "--jq", ".sha"]
    ).strip()
    if resolved != commit:
        raise SnapshotError(
            f"GitHub tag {tag} resolves to {resolved}, not {commit}"
        )
    release = json.loads(
        gh_output(
            [
                "release",
                "view",
                tag,
                "--repo",
                GITHUB_REPO,
                "--json",
                "tagName,isDraft,isImmutable",
            ]
        )
    )
    if release.get("tagName") != tag:
        raise SnapshotError(f"GitHub release tag mismatch for {tag}")
    if release.get("isDraft") is not False:
        raise SnapshotError(f"GitHub release {tag} is a draft")
    if release.get("isImmutable") is not True:
        raise SnapshotError(f"GitHub release {tag} is not immutable")
    for artifact in artifacts:
        gh_output(
            [
                "release",
                "verify-asset",
                tag,
                str(artifact),
                "--repo",
                GITHUB_REPO,
            ]
        )


def artifact_entry(path: Path, version: str, format_name: str) -> dict[str, Any]:
    expected = f"NeAntik-{version}-arm64-notarized.{format_name}"
    if path.name != expected:
        raise SnapshotError(f"Expected {expected}, got {path.name}")
    return {
        "format": format_name,
        "filename": expected,
        "url": f"https://affpapa.org/neantik/downloads/{expected}",
        "sizeBytes": path.stat().st_size,
        "sha256": file_sha256(path),
        "developerIdSigned": True,
        "notarized": True,
        "stapled": True,
        "gatekeeper": "accepted",
    }


def build_snapshot(args: argparse.Namespace) -> dict[str, str]:
    project_root = args.project_root.resolve()
    output = args.output.resolve()
    if output.exists() or output.is_symlink():
        raise SnapshotError(f"Output already exists: {output}")
    release_date = dt.date.fromisoformat(args.release_date)
    release_tag = getattr(args, "release_tag", None)
    release_commit = getattr(args, "release_commit", None)
    if bool(release_tag) != bool(release_commit):
        raise SnapshotError(
            "--release-tag and --release-commit must be used together"
        )
    # The worktree that runs this script is the release tooling. Requiring it
    # to be clean stays a hard gate, but its commit never becomes the
    # published source when an explicit release source is pinned.
    tooling_commit = git_commit(project_root)
    dmg = regular_file(args.dmg.resolve())
    zip_file = regular_file(args.zip.resolve())
    if release_tag and release_commit:
        verify_release_source(
            project_root, release_tag, release_commit, (dmg, zip_file)
        )
        commit = release_commit

        def source_bytes(relative: str) -> bytes:
            return read_source_bytes(project_root, commit, relative)

        version, build = parse_version(source_bytes("Resources/Info.plist"))
        if release_tag != f"v{version}":
            raise SnapshotError(
                f"Release tag {release_tag} does not match source version "
                f"{version}"
            )
        runtime_lock = json.loads(
            source_bytes("runtime/fingerprint-chromium.lock.json")
        )
        changelog = source_bytes("CHANGELOG.md").decode("utf-8")
        content = json.loads(
            source_bytes("ops/affpapa/bootstrap/content.json")
        )
        if not isinstance(content, dict):
            raise SnapshotError("Release source content.json must be an object")
    else:
        commit = tooling_commit
        version, build = read_version(project_root)
        runtime_lock = load_json(
            project_root / "runtime/fingerprint-chromium.lock.json"
        )
        changelog = (project_root / "CHANGELOG.md").read_text(encoding="utf-8")
        content = load_json(project_root / "ops/affpapa/bootstrap/content.json")
    runtime_version = str(
        runtime_lock["fingerprintChromium"]["chromiumVersion"]
    )
    artifacts = [
        artifact_entry(dmg, version, "dmg"),
        artifact_entry(zip_file, version, "zip"),
    ]
    release = {
        "schemaVersion": 1,
        "product": "NeAntik",
        "version": version,
        "build": build,
        "releaseDate": release_date.isoformat(),
        "status": "public-alpha",
        "distribution": "direct",
        "platform": {
            "operatingSystem": "macOS 14 or later",
            "architecture": "arm64",
            "hardware": "Apple Silicon",
        },
        "runtime": {"name": "Chromium", "version": runtime_version, "gpu": "Metal"},
        "source": {
            "repository": "https://github.com/AffPapa/neantik",
            "tag": f"v{version}",
            "commit": commit,
            "release": f"https://github.com/AffPapa/neantik/releases/tag/v{version}",
        },
        "artifacts": artifacts,
        "privacy": {
            "telemetry": "disabled",
            "profileData": "local-only",
            "proxyPasswords": "macOS Keychain",
        },
        "securityBaseline": {
            "runtimeVersion": runtime_version,
            "source": "Chrome Releases",
            "releaseChannel": "public-alpha",
        },
        "limitations": [
            "Public-alpha profile isolation is verified; strict production fingerprint coherence is not claimed.",
            "NeAntik does not guarantee anonymity and is not intended to bypass CAPTCHA, bans, anti-fraud systems, or third-party rules.",
            "Google Safe Browsing is not enabled in this privacy-oriented runtime.",
        ],
    }
    previous = [
        entry
        for entry in content.get("changelog", [])
        if isinstance(entry, dict) and entry.get("version") != version
    ]
    content.update(
        {
            "releaseVersion": version,
            "updatedAt": release_date.isoformat(),
            "changelog": [
                {
                    "version": version,
                    "build": build,
                    "date": russian_display_date(release_date),
                    "label": "Public Alpha",
                    "items": parse_release_notes(changelog, version, build),
                },
                *previous,
            ],
        }
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f".{output.name}.", dir=output.parent
    ) as temporary:
        staging = Path(temporary) / output.name
        staging.mkdir(mode=0o700)
        for source, entry in ((dmg, artifacts[0]), (zip_file, artifacts[1])):
            destination = staging / source.name
            shutil.copyfile(source, destination)
            destination.chmod(0o600)
            (staging / f"{source.name}.sha256").write_text(
                f"{entry['sha256']}  {source.name}\n", encoding="utf-8"
            )
        for name, payload in (("release.json", release), ("content.json", content)):
            (staging / name).write_text(
                json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
        validator = project_root / "ops/affpapa/server/neantik-validate-release"
        subprocess.run([str(validator), str(staging)], check=True)
        os.replace(staging, output)
    return {
        "output": str(output),
        "version": version,
        "build": str(build),
        "releaseTag": release_tag or f"v{version}",
        "releaseCommit": commit,
        "toolingCommit": tooling_commit,
        "releaseSourcePinned": "yes" if release_tag else "no",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--zip", type=Path, required=True)
    parser.add_argument("--release-date", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--release-tag",
        help=(
            "immutable GitHub tag the published binaries were built from, "
            "for example v0.3.20; requires --release-commit"
        ),
    )
    parser.add_argument(
        "--release-commit",
        help=(
            "exact release source commit the tag must resolve to; product "
            "facts are read from this commit instead of the worktree"
        ),
    )
    args = parser.parse_args()
    try:
        result = build_snapshot(args)
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f"AffPapa snapshot preparation failed: {error}", file=sys.stderr)
        return 1
    print(f"PASS: prepared canonical AffPapa snapshot: {result['output']}")
    print(f"  release version: {result['version']} ({result['build']})")
    print(
        f"  release source:  {result['releaseTag']} "
        f"{result['releaseCommit']} (pinned: {result['releaseSourcePinned']})"
    )
    print(f"  release tooling: {result['toolingCommit']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
