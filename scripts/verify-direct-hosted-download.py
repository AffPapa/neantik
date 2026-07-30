#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
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
LEGACY_ARCHIVE_ALLOWLIST = {
    (
        "NeAntik-0.3.12-arm64-notarized.zip",
        "b8a791056a8857339e1a52e48a81181f49525d2737cf985886b0b1aa05b8fc73",
    ),
}
CANDIDATE_MANIFEST_SCRIPT = (
    PROJECT_ROOT / "scripts" / "direct-candidate-manifest.py"
)
CANDIDATE_SPEC = importlib.util.spec_from_file_location(
    "direct_candidate_manifest_for_hosted_download",
    CANDIDATE_MANIFEST_SCRIPT,
)
assert CANDIDATE_SPEC and CANDIDATE_SPEC.loader
CANDIDATE = importlib.util.module_from_spec(CANDIDATE_SPEC)
sys.modules[CANDIDATE_SPEC.name] = CANDIDATE
CANDIDATE_SPEC.loader.exec_module(CANDIDATE)
SNAPSHOT_SCRIPT = PROJECT_ROOT / "scripts" / "release_input_snapshot.py"
SNAPSHOT_SPEC = importlib.util.spec_from_file_location(
    "release_input_snapshot_for_hosted_download",
    SNAPSHOT_SCRIPT,
)
assert SNAPSHOT_SPEC and SNAPSHOT_SPEC.loader
SNAPSHOT = importlib.util.module_from_spec(SNAPSHOT_SPEC)
sys.modules[SNAPSHOT_SPEC.name] = SNAPSHOT
SNAPSHOT_SPEC.loader.exec_module(SNAPSHOT)


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


def verify_archive_candidate_manifest(
    archive: Path,
    manifest: Path,
    release_channel: str,
) -> None:
    if release_channel not in {"public-alpha", "production"}:
        raise HostedDownloadError(
            "release channel must be public-alpha or production"
        )
    if not manifest.is_file() or manifest.is_symlink():
        raise HostedDownloadError(
            f"candidate manifest is missing or unsafe: {manifest}"
        )
    with tempfile.TemporaryDirectory(
        prefix="neantik-hosted-candidate-"
    ) as temporary:
        extraction_root = Path(temporary)
        app = extract_candidate_app(archive, extraction_root)
        try:
            CANDIDATE.verify_manifest(
                app,
                manifest,
                release_channel=release_channel,
            )
        except (CANDIDATE.CandidateManifestError, OSError) as error:
            raise HostedDownloadError(
                f"hosted app does not match candidate manifest: {error}"
            ) from error


def extract_candidate_app(
    archive: Path,
    extraction_root: Path,
) -> Path:
    completed = subprocess.run(
        ["ditto", "-x", "-k", str(archive), str(extraction_root)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise HostedDownloadError(
            "cannot extract hosted candidate archive:\n"
            + completed.stdout.strip()
        )
    app = extraction_root / "NeAntik.app"
    if not app.is_dir() or app.is_symlink():
        raise HostedDownloadError(
            "hosted archive must contain one top-level NeAntik.app"
        )
    unexpected_apps = [
        path
        for path in extraction_root.glob("*.app")
        if path.name != "NeAntik.app"
    ]
    if unexpected_apps:
        raise HostedDownloadError(
            "hosted archive contains an unexpected top-level app"
        )
    return app


Downloader = Callable[[str, Path, int], None]
ArchiveVerifier = Callable[[Path], None]
CandidateVerifier = Callable[[Path, Path, str], None]
ReleaseEvidenceVerifier = Callable[[Path, Path, Path, str], None]


def verify_release_evidence_contract(
    manifest: Path,
    evidence: Path,
    attestation: Path,
    release_channel: str,
    *,
    project_root: Path,
    candidate_archive: Path,
) -> None:
    with tempfile.TemporaryDirectory(
        prefix="neantik-hosted-evidence-app-"
    ) as temporary:
        app = extract_candidate_app(
            candidate_archive,
            Path(temporary),
        )
        completed = subprocess.run(
            [
                sys.executable,
                str(
                    project_root
                    / "scripts"
                    / "verify-public-artifact-privacy.py"
                ),
                str(attestation),
                "--private-evidence",
                str(evidence),
                "--attestation",
                str(attestation),
                "--integrated-app",
                str(app),
                "--candidate-manifest",
                str(manifest),
                "--release-channel",
                release_channel,
            ],
            cwd=project_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if completed.returncode != 0:
            raise HostedDownloadError(
                "authenticated fingerprint release evidence "
                "verification failed:\n"
                + completed.stdout.strip()
            )


def _verify_pinned_hosted_download(
    *,
    project_root: Path,
    archive: Path,
    archive_name: str,
    download_url: str | None = None,
    downloader: Downloader | None = None,
    archive_verifier: ArchiveVerifier | None = None,
    candidate_manifest: Path | None = None,
    release_channel: str | None = None,
    candidate_verifier: CandidateVerifier | None = None,
    fingerprint_evidence: Path | None = None,
    fingerprint_attestation: Path | None = None,
    release_evidence_verifier: ReleaseEvidenceVerifier | None = None,
    legacy_archive_only: bool = False,
) -> dict[str, str | int]:
    if candidate_manifest is not None:
        if not candidate_manifest.is_file() or candidate_manifest.is_symlink():
            raise HostedDownloadError(
                f"candidate manifest is missing or unsafe: {candidate_manifest}"
            )
        candidate_manifest = candidate_manifest.resolve()
        if release_channel not in {"public-alpha", "production"}:
            raise HostedDownloadError(
                "release channel must be public-alpha or production"
            )
        candidate_verifier = (
            candidate_verifier or verify_archive_candidate_manifest
        )
        assert fingerprint_evidence is not None
        assert fingerprint_attestation is not None
        for label, path in (
            ("fingerprint evidence", fingerprint_evidence),
            ("fingerprint attestation", fingerprint_attestation),
        ):
            if not path.is_file() or path.is_symlink():
                raise HostedDownloadError(f"{label} is missing or unsafe")
        release_evidence_verifier = (
            release_evidence_verifier
            or (
                lambda manifest, evidence, attestation, channel:
                    verify_release_evidence_contract(
                        manifest,
                        evidence,
                        attestation,
                        channel,
                        project_root=project_root,
                        candidate_archive=archive,
                    )
            )
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
    if (
        legacy_archive_only
        and (archive_name, expected_sha256) not in LEGACY_ARCHIVE_ALLOWLIST
    ):
        raise HostedDownloadError(
            "legacy archive-only mode is restricted to allowlisted "
            "historical release name and SHA-256 pairs"
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
    if candidate_manifest is not None:
        assert release_channel is not None and candidate_verifier is not None
        candidate_verifier(
            archive,
            candidate_manifest,
            release_channel,
        )
        assert release_evidence_verifier is not None
        release_evidence_verifier(
            candidate_manifest,
            fingerprint_evidence.resolve(),
            fingerprint_attestation.resolve(),
            release_channel,
        )
    with tempfile.TemporaryDirectory(prefix="neantik-hosted-zip-") as temporary:
        download_root = Path(temporary)
        downloaded = download_root / archive_name
        downloader(download_url, downloaded, expected_size)
        if not downloaded.is_file() or downloaded.is_symlink():
            raise HostedDownloadError("download did not produce a regular archive")
        pinned_root = download_root / "pinned"
        pinned_root.mkdir(mode=0o700)
        try:
            downloaded_snapshot = SNAPSHOT.snapshot_release_input(
                downloaded,
                pinned_root / archive_name,
                maximum_bytes=16 * 1_024 * 1_024 * 1_024,
            )
        except SNAPSHOT.ReleaseInputSnapshotError as error:
            raise HostedDownloadError(
                "downloaded release snapshot failed"
            ) from error
        pinned_download = downloaded_snapshot.pinned
        remote_sha256 = downloaded_snapshot.sha256
        remote_size = downloaded_snapshot.size
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
        pinned_sidecar = pinned_download.with_suffix(
            pinned_download.suffix + ".sha256"
        )
        pinned_sidecar.write_text(
            f"{remote_sha256}  {archive_name}\n",
            encoding="utf-8",
        )
        pinned_sidecar.chmod(0o600)
        archive_verifier(pinned_download)
        if candidate_manifest is not None:
            assert release_channel is not None and candidate_verifier is not None
            candidate_verifier(
                pinned_download,
                candidate_manifest,
                release_channel,
            )
        try:
            SNAPSHOT.assert_snapshot_source_unchanged(
                downloaded_snapshot,
                maximum_bytes=16 * 1_024 * 1_024 * 1_024,
            )
            SNAPSHOT.assert_snapshot_copy_unchanged(
                downloaded_snapshot,
                maximum_bytes=16 * 1_024 * 1_024 * 1_024,
            )
        except SNAPSHOT.ReleaseInputSnapshotError as error:
            raise HostedDownloadError(
                "downloaded release changed during verification"
            ) from error

    return {
        "archiveName": archive_name,
        "downloadURL": download_url,
        "sha256": expected_sha256,
        "sizeBytes": expected_size,
        "status": (
            "hosted-zip-byte-identical-gatekeeper-candidate-and-evidence-verified"
            if candidate_manifest is not None
            else "legacy-hosted-zip-byte-identical-and-gatekeeper-verified"
        ),
    }


def verify_hosted_download(
    *,
    project_root: Path = PROJECT_ROOT,
    archive: Path | None = None,
    download_url: str | None = None,
    downloader: Downloader | None = None,
    archive_verifier: ArchiveVerifier | None = None,
    candidate_manifest: Path | None = None,
    release_channel: str | None = None,
    candidate_verifier: CandidateVerifier | None = None,
    fingerprint_evidence: Path | None = None,
    fingerprint_attestation: Path | None = None,
    release_evidence_verifier: ReleaseEvidenceVerifier | None = None,
    legacy_archive_only: bool = False,
) -> dict[str, str | int]:
    project_root_lexical = project_root.absolute()
    archive_name = expected_archive_name(project_root_lexical)
    archive_input_lexical = (
        project_root_lexical / "dist" / archive_name
        if archive is None
        else archive.absolute()
    )
    expected_input_lexical = (
        project_root_lexical / "dist" / archive_name
    )
    if archive_input_lexical != expected_input_lexical:
        raise HostedDownloadError(
            "local archive must be the final dist artifact"
        )
    project_root = project_root.resolve()
    expected_archive = project_root / "dist" / archive_name
    archive_input = expected_archive if archive is None else archive
    archive_lexical = expected_archive
    expected_lexical = expected_archive.absolute()
    if archive_lexical != expected_lexical:
        raise HostedDownloadError(
            f"local archive must be the final dist artifact: {expected_archive}"
        )
    if (
        (project_root_lexical / "dist").is_symlink()
        or archive_input_lexical.is_symlink()
    ):
        raise HostedDownloadError(
            f"local archive must not be a symlink: {archive_input}"
        )
    archive_source = archive_lexical
    if archive_source.name != archive_name:
        raise HostedDownloadError(
            f"local archive must be named {archive_name!r}, "
            f"got {archive_source.name!r}"
        )
    release_inputs = (
        candidate_manifest,
        release_channel,
        fingerprint_evidence,
        fingerprint_attestation,
    )
    if legacy_archive_only:
        if any(value is not None for value in release_inputs):
            raise HostedDownloadError(
                "legacy archive-only mode cannot accept new-release evidence"
            )
    elif any(value is None for value in release_inputs):
        raise HostedDownloadError(
            "new releases require candidate manifest, release channel, "
            "authenticated fingerprint evidence and public attestation together"
        )

    snapshot_limits = {
        "archive": 16 * 1_024 * 1_024 * 1_024,
        "sidecar": 4 * 1_024,
        "manifest": CANDIDATE.MAXIMUM_MANIFEST_BYTES,
        "evidence": 8 * 1_024 * 1_024,
        "attestation": 1 * 1_024 * 1_024,
    }
    with tempfile.TemporaryDirectory(
        prefix="neantik-hosted-input-set-"
    ) as temporary:
        transaction_root = Path(temporary)
        source_snapshots: list[
            tuple[SNAPSHOT.ReleaseInputSnapshot, int]
        ] = []
        try:
            archive_snapshot = SNAPSHOT.snapshot_release_input(
                archive_source,
                transaction_root / archive_name,
                maximum_bytes=snapshot_limits["archive"],
            )
            sidecar_snapshot = SNAPSHOT.snapshot_release_input(
                archive_source.with_suffix(
                    archive_source.suffix + ".sha256"
                ),
                transaction_root / (archive_name + ".sha256"),
                maximum_bytes=snapshot_limits["sidecar"],
            )
            source_snapshots.extend(
                (
                    (archive_snapshot, snapshot_limits["archive"]),
                    (sidecar_snapshot, snapshot_limits["sidecar"]),
                )
            )
            pinned_manifest = None
            pinned_evidence = None
            pinned_attestation = None
            if candidate_manifest is not None:
                assert fingerprint_evidence is not None
                assert fingerprint_attestation is not None
                manifest_snapshot = SNAPSHOT.snapshot_release_input(
                    candidate_manifest,
                    transaction_root / "direct-candidate-manifest.json",
                    maximum_bytes=snapshot_limits["manifest"],
                )
                evidence_snapshot = SNAPSHOT.snapshot_release_input(
                    fingerprint_evidence,
                    transaction_root / "fingerprint-evidence-schema8.json",
                    maximum_bytes=snapshot_limits["evidence"],
                )
                attestation_snapshot = SNAPSHOT.snapshot_release_input(
                    fingerprint_attestation,
                    transaction_root / "fingerprint-attestation.json",
                    maximum_bytes=snapshot_limits["attestation"],
                )
                source_snapshots.extend(
                    (
                        (manifest_snapshot, snapshot_limits["manifest"]),
                        (evidence_snapshot, snapshot_limits["evidence"]),
                        (
                            attestation_snapshot,
                            snapshot_limits["attestation"],
                        ),
                    )
                )
                pinned_manifest = manifest_snapshot.pinned
                pinned_evidence = evidence_snapshot.pinned
                pinned_attestation = attestation_snapshot.pinned
        except SNAPSHOT.ReleaseInputSnapshotError as error:
            raise HostedDownloadError(
                "release input snapshot failed"
            ) from error

        result = _verify_pinned_hosted_download(
            project_root=project_root,
            archive=archive_snapshot.pinned,
            archive_name=archive_name,
            download_url=download_url,
            downloader=downloader,
            archive_verifier=archive_verifier,
            candidate_manifest=pinned_manifest,
            release_channel=release_channel,
            candidate_verifier=candidate_verifier,
            fingerprint_evidence=pinned_evidence,
            fingerprint_attestation=pinned_attestation,
            release_evidence_verifier=release_evidence_verifier,
            legacy_archive_only=legacy_archive_only,
        )
        try:
            for snapshot, maximum_bytes in source_snapshots:
                SNAPSHOT.assert_snapshot_source_unchanged(
                    snapshot,
                    maximum_bytes=maximum_bytes,
                )
                SNAPSHOT.assert_snapshot_copy_unchanged(
                    snapshot,
                    maximum_bytes=maximum_bytes,
                )
        except SNAPSHOT.ReleaseInputSnapshotError as error:
            raise HostedDownloadError(
                "release input changed during hosted verification"
            ) from error
        return result


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
    parser.add_argument(
        "--candidate-manifest",
        type=Path,
        help=(
            "Immutable prepared-candidate manifest. New releases must pass "
            "this together with --release-channel."
        ),
    )
    parser.add_argument(
        "--release-channel",
        choices=("public-alpha", "production"),
        help="Qualification channel bound by the candidate manifest.",
    )
    parser.add_argument(
        "--fingerprint-evidence",
        type=Path,
        help="Private authenticated schema-8 evidence for this candidate.",
    )
    parser.add_argument(
        "--fingerprint-attestation",
        type=Path,
        help="Public-safe attestation derived from the schema-8 evidence.",
    )
    parser.add_argument(
        "--legacy-archive-only",
        action="store_true",
        help=(
            "Historical compatibility only. Skips candidate and schema-8 "
            "evidence binding; forbidden for new releases."
        ),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = verify_hosted_download(
            project_root=args.project_root,
            archive=args.archive,
            download_url=args.download_url,
            candidate_manifest=args.candidate_manifest,
            release_channel=args.release_channel,
            fingerprint_evidence=args.fingerprint_evidence,
            fingerprint_attestation=args.fingerprint_attestation,
            legacy_archive_only=args.legacy_archive_only,
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
