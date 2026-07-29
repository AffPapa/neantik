#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable
from urllib.parse import unquote, urlparse


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class HostedDownloadError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_archive_name(project_root: Path) -> str:
    try:
        with (project_root / "Resources" / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        version = str(info["CFBundleShortVersionString"]).strip()
    except (OSError, KeyError, plistlib.InvalidFileException) as error:
        raise HostedDownloadError(f"cannot read app version: {error}") from error
    if not version:
        raise HostedDownloadError("CFBundleShortVersionString is empty")
    return f"NeAntik-{version}-arm64-notarized.zip"


def validate_download_url(url: str, *, archive_name: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise HostedDownloadError("download URL must be absolute HTTPS")
    if parsed.username or parsed.password:
        raise HostedDownloadError("download URL must not contain credentials")
    if parsed.query or parsed.fragment:
        raise HostedDownloadError(
            "download URL must not contain a query string or fragment"
        )
    if Path(unquote(parsed.path)).name != archive_name:
        raise HostedDownloadError(
            f"download URL basename must be {archive_name!r}"
        )
    return url


def read_recorded_checksum(archive: Path) -> str:
    sidecar = archive.with_suffix(archive.suffix + ".sha256")
    if not sidecar.is_file() or sidecar.is_symlink():
        raise HostedDownloadError(
            f"checksum sidecar is missing or unsafe: {sidecar}"
        )
    fields = sidecar.read_text(encoding="utf-8").split()
    if len(fields) < 2:
        raise HostedDownloadError(f"checksum sidecar is malformed: {sidecar}")
    digest, recorded_name = fields[0], Path(fields[-1]).name
    if recorded_name != archive.name:
        raise HostedDownloadError(
            f"checksum sidecar names {recorded_name!r}, expected {archive.name!r}"
        )
    if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
        raise HostedDownloadError("checksum sidecar does not contain lowercase SHA-256")
    return digest


def download_with_curl(
    url: str,
    destination: Path,
    expected_size: int,
    *,
    timeout: int = 900,
) -> None:
    completed = subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--tlsv1.2",
            "--max-time",
            str(timeout),
            "--max-filesize",
            str(expected_size),
            "--user-agent",
            "NeAntik-release-verifier/1.0",
            "--output",
            str(destination),
            url,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip()
        raise HostedDownloadError(
            f"download failed with curl exit {completed.returncode}: {detail}"
        )


def verify_archive_with_local_gate(archive: Path, *, project_root: Path) -> None:
    completed = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts" / "verify-direct-notarized-archive.py"),
            "--project-root",
            str(project_root),
            "--archive",
            str(archive),
        ],
        cwd=project_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise HostedDownloadError(
            "notarized archive verification failed:\n" + completed.stdout.strip()
        )


Downloader = Callable[[str, Path, int], None]
ArchiveVerifier = Callable[[Path], None]


def verify_hosted_download(
    *,
    project_root: Path = PROJECT_ROOT,
    archive: Path | None = None,
    download_url: str | None = None,
    downloader: Downloader | None = None,
    archive_verifier: ArchiveVerifier | None = None,
) -> dict[str, str | int]:
    project_root = project_root.resolve()
    archive_name = expected_archive_name(project_root)
    expected_archive = project_root / "dist" / archive_name
    archive_input = (
        project_root / "dist" / archive_name
        if archive is None
        else archive
    )
    if archive_input.is_symlink():
        raise HostedDownloadError(
            f"local archive must not be a symlink: {archive_input}"
        )
    archive = archive_input.resolve()
    if archive != expected_archive.resolve():
        raise HostedDownloadError(
            f"local archive must be the final dist artifact: {expected_archive}"
        )
    if archive.name != archive_name:
        raise HostedDownloadError(
            f"local archive must be named {archive_name!r}, got {archive.name!r}"
        )
    if not archive.is_file() or archive.is_symlink():
        raise HostedDownloadError(
            f"local archive is missing or unsafe: {archive}"
        )

    download_url = download_url or os.environ.get(
        "NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL"
    )
    if not download_url:
        raise HostedDownloadError(
            "pass --download-url or set NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL"
        )
    validate_download_url(download_url, archive_name=archive_name)

    expected_sha256 = read_recorded_checksum(archive)
    local_sha256 = sha256_file(archive)
    if local_sha256 != expected_sha256:
        raise HostedDownloadError(
            "local archive SHA-256 differs from its sidecar: "
            f"{local_sha256} != {expected_sha256}"
        )
    expected_size = archive.stat().st_size
    if expected_size <= 0:
        raise HostedDownloadError("local archive is empty")

    downloader = downloader or download_with_curl
    if archive_verifier is None:
        archive_verifier = lambda candidate: verify_archive_with_local_gate(
            candidate,
            project_root=project_root,
        )

    archive_verifier(archive)
    with tempfile.TemporaryDirectory(prefix="neantik-hosted-zip-") as temporary:
        downloaded = Path(temporary) / archive_name
        downloader(download_url, downloaded, expected_size)
        if not downloaded.is_file() or downloaded.is_symlink():
            raise HostedDownloadError("download did not produce a regular archive")
        remote_sha256 = sha256_file(downloaded)
        remote_size = downloaded.stat().st_size
        if remote_sha256 != expected_sha256:
            raise HostedDownloadError(
                "downloaded SHA-256 differs from local final archive: "
                f"{remote_sha256} != {expected_sha256}"
            )
        if remote_size != expected_size:
            raise HostedDownloadError(
                "downloaded size differs from local final archive: "
                f"{remote_size} != {expected_size}"
            )
        downloaded.with_suffix(downloaded.suffix + ".sha256").write_text(
            f"{remote_sha256}  {archive_name}\n",
            encoding="utf-8",
        )
        archive_verifier(downloaded)

    return {
        "archiveName": archive_name,
        "downloadURL": download_url,
        "sha256": expected_sha256,
        "sizeBytes": expected_size,
        "status": "hosted-zip-byte-identical-and-gatekeeper-verified",
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Download the public NeAntik ZIP into a fresh directory and repeat "
            "the notarized archive, integrated runtime, and Gatekeeper gates."
        ),
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--archive", type=Path)
    parser.add_argument(
        "--download-url",
        default=os.environ.get("NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL"),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = verify_hosted_download(
            project_root=args.project_root,
            archive=args.archive,
            download_url=args.download_url,
        )
    except (OSError, HostedDownloadError) as error:
        print(f"Direct hosted ZIP verification failed: {error}", file=sys.stderr)
        return 65
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print("PASS: Direct hosted ZIP contract verified.")
        print(f"Archive: {result['archiveName']}")
        print(f"Download URL: {result['downloadURL']}")
        print(f"Size: {result['sizeBytes']} bytes")
        print(f"SHA-256: {result['sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
