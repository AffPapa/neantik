#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path
from pathlib import PurePosixPath
from typing import Callable
from urllib.parse import unquote, urlparse

import release_input_snapshot as SNAPSHOT
import release_transaction as TRANSACTION


MAXIMUM_ARCHIVE_BYTES = 16 * 1024 * 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 16 * 1024 * 1024
MAXIMUM_EVIDENCE_BYTES = 8 * 1024 * 1024
MAXIMUM_ATTESTATION_BYTES = 1024 * 1024
MAXIMUM_INFO_PLIST_BYTES = 1024 * 1024
MAXIMUM_ARCHIVE_ENTRIES = 200_000
MAXIMUM_UNCOMPRESSED_BYTES = 32 * 1024 * 1024 * 1024


class DirectNotaryTransactionError(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    output: str
    stderr: str = ""


@dataclass(frozen=True)
class CandidateInputs:
    info: SNAPSHOT.ReleaseInputSnapshot
    manifest: SNAPSHOT.ReleaseInputSnapshot
    evidence: SNAPSHOT.ReleaseInputSnapshot
    attestation: SNAPSHOT.ReleaseInputSnapshot


CommandRunner = Callable[[list[str], Path], CommandResult]
PhaseHook = Callable[[str, dict[str, Path]], None]


def default_runner(command: list[str], cwd: Path) -> CommandResult:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30 * 60,
        )
    except subprocess.TimeoutExpired as error:
        detail = str(error.stderr or error.stdout or "").strip()
        return CommandResult(
            124,
            "",
            "command timed out" + (f": {detail}" if detail else ""),
        )
    return CommandResult(
        completed.returncode,
        completed.stdout.strip(),
        completed.stderr.strip(),
    )


def run_checked(
    command: list[str],
    *,
    cwd: Path,
    runner: CommandRunner,
    label: str,
    include_stderr: bool = False,
) -> str:
    result = runner(command, cwd)
    if result.returncode != 0:
        detail = "\n".join(
            part
            for part in (
                result.output.strip(),
                result.stderr.strip(),
            )
            if part
        )
        raise DirectNotaryTransactionError(
            f"{label} failed" + (f":\n{detail}" if detail else "")
        )
    if include_stderr and result.stderr:
        return "\n".join(
            part
            for part in (
                result.output.strip(),
                result.stderr.strip(),
            )
            if part
        )
    return result.output


def _reject_duplicate_json_pairs(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DirectNotaryTransactionError(
                "Apple notary JSON contains duplicate keys"
            )
        result[key] = value
    return result


def parse_notary_result(
    output: str,
    *,
    expected_identifier: str | None = None,
) -> str:
    try:
        payload = json.loads(
            output,
            object_pairs_hook=_reject_duplicate_json_pairs,
        )
    except (json.JSONDecodeError, TypeError) as error:
        raise DirectNotaryTransactionError(
            "Apple notary response is not strict JSON"
        ) from error
    if not isinstance(payload, dict):
        raise DirectNotaryTransactionError(
            "Apple notary response must be a JSON object"
        )
    identifier = payload.get("id")
    status_value = payload.get("status")
    if not isinstance(identifier, str) or not isinstance(
        status_value,
        str,
    ):
        raise DirectNotaryTransactionError(
            "Apple notary response is missing id or status"
        )
    try:
        canonical_identifier = str(uuid.UUID(identifier))
    except ValueError as error:
        raise DirectNotaryTransactionError(
            "Apple notary response contains an invalid id"
        ) from error
    if identifier != canonical_identifier:
        raise DirectNotaryTransactionError(
            "Apple notary id is not canonical"
        )
    if status_value != "Accepted":
        raise DirectNotaryTransactionError(
            f"Apple notarization status is {status_value}, not Accepted"
        )
    if (
        expected_identifier is not None
        and identifier != expected_identifier
    ):
        raise DirectNotaryTransactionError(
            "Apple notary info does not match the submitted id"
        )
    return identifier


def assert_safe_archive_members(archive: Path) -> None:
    try:
        with zipfile.ZipFile(archive) as zip_file:
            entries = zip_file.infolist()
            if not entries or len(entries) > MAXIMUM_ARCHIVE_ENTRIES:
                raise DirectNotaryTransactionError(
                    "release transaction archive has an unsafe entry count"
                )
            names: set[str] = set()
            member_parts: list[tuple[str, ...]] = []
            symlink_names: set[str] = set()
            total = 0
            for entry in entries:
                name = entry.filename
                if (
                    not name
                    or name in names
                    or "\x00" in name
                    or name.startswith("/")
                ):
                    raise DirectNotaryTransactionError(
                        "release transaction archive contains an unsafe path"
                    )
                names.add(name)
                parts = tuple(part for part in name.split("/") if part)
                if (
                    not parts
                    or parts[0] != "NeAntik.app"
                    or any(part in {".", ".."} for part in parts)
                    or "__MACOSX" in parts
                    or parts[-1] == ".DS_Store"
                    or parts[-1].startswith("._")
                ):
                    raise DirectNotaryTransactionError(
                        "release transaction archive contains an unexpected entry"
                    )
                member_parts.append(parts)
                total += entry.file_size
                if total > MAXIMUM_UNCOMPRESSED_BYTES:
                    raise DirectNotaryTransactionError(
                        "release transaction archive expands beyond its limit"
                    )
                unix_mode = (entry.external_attr >> 16) & 0xFFFF
                if stat.S_ISLNK(unix_mode):
                    if entry.file_size <= 0 or entry.file_size > 4096:
                        raise DirectNotaryTransactionError(
                            "release archive symlink target is unsafe"
                        )
                    try:
                        target_text = zip_file.read(entry).decode(
                            "utf-8",
                            errors="strict",
                        )
                    except UnicodeDecodeError as error:
                        raise DirectNotaryTransactionError(
                            "release archive symlink target is invalid"
                        ) from error
                    target = PurePosixPath(target_text)
                    if target.is_absolute() or "\x00" in target_text:
                        raise DirectNotaryTransactionError(
                            "release archive symlink escapes the app"
                        )
                    stack = list(parts[:-1])
                    for component in target.parts:
                        if component in {"", "."}:
                            continue
                        if component == "..":
                            if len(stack) <= 1:
                                raise DirectNotaryTransactionError(
                                    "release archive symlink escapes the app"
                                )
                            stack.pop()
                        else:
                            stack.append(component)
                    if not stack or stack[0] != "NeAntik.app":
                        raise DirectNotaryTransactionError(
                            "release archive symlink escapes the app"
                        )
                    symlink_names.add("/".join(parts))
            for parts in member_parts:
                for index in range(1, len(parts)):
                    if "/".join(parts[:index]) in symlink_names:
                        raise DirectNotaryTransactionError(
                            "release archive writes through a symlink"
                        )
    except zipfile.BadZipFile as error:
        raise DirectNotaryTransactionError(
            "release transaction archive is not a valid ZIP"
        ) from error


def extract_candidate_app(
    archive: Path,
    destination: Path,
    *,
    project_root: Path,
    runner: CommandRunner,
) -> Path:
    assert_safe_archive_members(archive)
    run_checked(
        ["ditto", "-x", "-k", str(archive), str(destination)],
        cwd=project_root,
        runner=runner,
        label="candidate archive extraction",
    )
    children = list(destination.iterdir())
    app = destination / "NeAntik.app"
    if (
        len(children) != 1
        or children[0] != app
        or not app.is_dir()
        or app.is_symlink()
    ):
        raise DirectNotaryTransactionError(
            "release archive must contain only one top-level NeAntik.app"
        )
    return app


def read_version(info_plist: Path) -> str:
    with info_plist.open("rb") as file:
        value = plistlib.load(file).get("CFBundleShortVersionString")
    version = str(value or "")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", version):
        raise DirectNotaryTransactionError(
            "Direct version must use numeric major.minor.patch"
        )
    return version


def validate_hosted_download_url(
    url: str,
    *,
    archive_name: str,
) -> None:
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or Path(unquote(parsed.path)).name != archive_name
    ):
        raise DirectNotaryTransactionError(
            "hosted download URL does not match the pinned archive"
        )


def snapshot_candidate_inputs(
    *,
    info_plist: Path,
    manifest: Path,
    evidence: Path,
    attestation: Path,
    destination: Path,
) -> CandidateInputs:
    try:
        return CandidateInputs(
            info=SNAPSHOT.snapshot_release_input(
                info_plist,
                destination / "Info.plist",
                maximum_bytes=MAXIMUM_INFO_PLIST_BYTES,
            ),
            manifest=SNAPSHOT.snapshot_release_input(
                manifest,
                destination / "direct-candidate-manifest.json",
                maximum_bytes=MAXIMUM_MANIFEST_BYTES,
            ),
            evidence=SNAPSHOT.snapshot_release_input(
                evidence,
                destination / "fingerprint-evidence-schema8.json",
                maximum_bytes=MAXIMUM_EVIDENCE_BYTES,
            ),
            attestation=SNAPSHOT.snapshot_release_input(
                attestation,
                destination / "fingerprint-attestation.json",
                maximum_bytes=MAXIMUM_ATTESTATION_BYTES,
            ),
        )
    except SNAPSHOT.ReleaseInputSnapshotError as error:
        raise DirectNotaryTransactionError(
            "candidate release inputs could not be pinned"
        ) from error


def assert_candidate_inputs_unchanged(inputs: CandidateInputs) -> None:
    for snapshot, maximum_bytes in (
        (inputs.info, MAXIMUM_INFO_PLIST_BYTES),
        (inputs.manifest, MAXIMUM_MANIFEST_BYTES),
        (inputs.evidence, MAXIMUM_EVIDENCE_BYTES),
        (inputs.attestation, MAXIMUM_ATTESTATION_BYTES),
    ):
        try:
            SNAPSHOT.assert_snapshot_source_unchanged(
                snapshot,
                maximum_bytes=maximum_bytes,
            )
            SNAPSHOT.assert_snapshot_copy_unchanged(
                snapshot,
                maximum_bytes=maximum_bytes,
            )
        except SNAPSHOT.ReleaseInputSnapshotError as error:
            raise DirectNotaryTransactionError(
                "candidate release input changed during notarization"
            ) from error


def verify_candidate_app(
    app: Path,
    *,
    project_root: Path,
    inputs: CandidateInputs,
    release_channel: str,
    runner: CommandRunner,
    full_preflight: bool,
) -> None:
    manifest = inputs.manifest.pinned
    evidence = inputs.evidence.pinned
    attestation = inputs.attestation.pinned
    commands: list[tuple[str, list[str]]] = [
        (
            "candidate manifest verification",
            [
                sys.executable,
                str(
                    project_root
                    / "scripts"
                    / "direct-candidate-manifest.py"
                ),
                "verify",
                "--app",
                str(app),
                "--manifest",
                str(manifest),
                "--release-channel",
                release_channel,
                "--fingerprint-evidence",
                str(evidence),
            ],
        ),
        (
            "fingerprint evidence envelope verification",
            [
                sys.executable,
                str(
                    project_root
                    / "scripts"
                    / "verify-fingerprint-evidence-envelope.py"
                ),
                "--manifest",
                str(manifest),
                "--envelope",
                str(evidence),
            ],
        ),
        (
            "public artifact privacy verification",
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
        ),
        (
            "integrated release verification",
            [
                str(
                    project_root
                    / "scripts"
                    / "verify-integrated-release.sh"
                ),
                str(app),
            ],
        ),
        (
            "code signature verification",
            [
                "codesign",
                "--verify",
                "--deep",
                "--strict",
                "--verbose=2",
                str(app),
            ],
        ),
    ]
    if full_preflight:
        baseline = [
            str(
                project_root
                / "scripts"
                / "verify-runtime-security-baseline.py"
            ),
            "--lock",
            str(
                app
                / "Contents"
                / "Resources"
                / "NeAntikRuntimeEvidence"
                / "fingerprint-chromium.lock.json"
            ),
        ]
        if release_channel == "public-alpha":
            baseline.append("--allow-public-alpha-tuples")
        commands[1:1] = [
            ("runtime security baseline", baseline),
            (
                "runtime security reference",
                [
                    str(
                        project_root
                        / "scripts"
                        / "verify-runtime-security-reference.py"
                    )
                ],
            ),
            (
                "Direct telemetry contract",
                [
                    str(
                        project_root
                        / "scripts"
                        / "verify-direct-telemetry-disabled.py"
                    )
                ],
            ),
            (
                "Direct update policy",
                [
                    str(
                        project_root
                        / "scripts"
                        / "verify-direct-update-policy.py"
                    )
                ],
            ),
            (
                "public fingerprint corpus",
                [
                    str(
                        project_root
                        / "scripts"
                        / "verify-public-fingerprint-corpus.py"
                    )
                ],
            ),
        ]
    for label, command in commands:
        run_checked(
            command,
            cwd=project_root,
            runner=runner,
            label=label,
        )
    signature = run_checked(
        ["codesign", "-dvvv", str(app)],
        cwd=project_root,
        runner=runner,
        label="Developer ID signature inspection",
        include_stderr=True,
    )
    if (
        "Authority=Developer ID Application:" not in signature
        or not re.search(r"(?m)^Timestamp=", signature)
    ):
        raise DirectNotaryTransactionError(
            "candidate lacks Developer ID Application authority or timestamp"
        )


def write_private_json(path: Path, payload: dict[str, object]) -> None:
    encoded = (
        json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise DirectNotaryTransactionError(
            "notary receipt output is unavailable"
        ) from error
    succeeded = False
    try:
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise DirectNotaryTransactionError(
                    "notary receipt write failed"
                )
            view = view[written:]
        os.fsync(descriptor)
        succeeded = True
    finally:
        os.close(descriptor)
        if not succeeded:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
    directory = os.open(
        path.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
    )
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def publish_private_receipt(
    receipt: Path,
    *,
    destination: Path,
) -> None:
    ensure_private_receipt_directory(destination.parent)
    try:
        snapshot = SNAPSHOT.snapshot_release_input(
            receipt,
            destination,
            maximum_bytes=1024 * 1024,
        )
        SNAPSHOT.assert_snapshot_copy_unchanged(
            snapshot,
            maximum_bytes=1024 * 1024,
        )
    except SNAPSHOT.ReleaseInputSnapshotError as error:
        raise DirectNotaryTransactionError(
            "notary receipt could not be published without overwrite"
        ) from error


def ensure_private_receipt_directory(directory: Path) -> None:
    directory.mkdir(mode=0o700, exist_ok=True)
    status = directory.stat(follow_symlinks=False)
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_uid != os.geteuid()
        or status.st_mode & 0o077
    ):
        raise DirectNotaryTransactionError(
            "notary receipt directory is unsafe"
        )


def _clear_directory_descriptor(descriptor: int) -> None:
    for name in os.listdir(descriptor):
        try:
            status = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            continue
        if stat.S_ISDIR(status.st_mode):
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            try:
                child = os.open(name, flags, dir_fd=descriptor)
            except OSError:
                continue
            try:
                opened = os.fstat(child)
                if (
                    opened.st_dev != status.st_dev
                    or opened.st_ino != status.st_ino
                ):
                    continue
                _clear_directory_descriptor(child)
            finally:
                os.close(child)
            try:
                current = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if (
                    current.st_dev == status.st_dev
                    and current.st_ino == status.st_ino
                ):
                    os.rmdir(name, dir_fd=descriptor)
            except OSError:
                continue
        else:
            try:
                current = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if (
                    current.st_dev == status.st_dev
                    and current.st_ino == status.st_ino
                ):
                    os.unlink(name, dir_fd=descriptor)
            except OSError:
                continue


def cleanup_exact_transaction(
    path: Path,
    *,
    descriptor: int,
    expected_device: int,
    expected_inode: int,
) -> None:
    try:
        status = os.fstat(descriptor)
    except OSError:
        return
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_dev != expected_device
        or status.st_ino != expected_inode
    ):
        return
    try:
        _clear_directory_descriptor(descriptor)
    except OSError:
        return
    parent_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        parent_flags |= os.O_NOFOLLOW
    try:
        parent = os.open(path.parent, parent_flags)
    except OSError:
        return
    try:
        current = os.stat(
            path.name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        if (
            stat.S_ISDIR(current.st_mode)
            and current.st_dev == expected_device
            and current.st_ino == expected_inode
        ):
            os.rmdir(path.name, dir_fd=parent)
    except OSError:
        return
    finally:
        os.close(parent)


def run_transaction(
    *,
    project_root: Path,
    app: Path,
    manifest: Path,
    evidence: Path,
    attestation: Path,
    release_channel: str,
    notary_profile: str,
    runner: CommandRunner = default_runner,
    phase_hook: PhaseHook | None = None,
) -> dict[str, str]:
    project_root = project_root.resolve()
    dist = project_root / "dist"
    try:
        dist_status = dist.stat(follow_symlinks=False)
    except OSError as error:
        raise DirectNotaryTransactionError(
            "dist directory is unavailable"
        ) from error
    if (
        not stat.S_ISDIR(dist_status.st_mode)
        or dist.is_symlink()
        or dist_status.st_uid != os.geteuid()
        or dist_status.st_mode & 0o022
    ):
        raise DirectNotaryTransactionError(
            "dist directory is unsafe"
        )
    expected_app = dist / "NeAntik.app"
    if app.resolve() != expected_app.resolve():
        raise DirectNotaryTransactionError(
            "notarization requires the exact prepared dist/NeAntik.app"
        )
    if (
        release_channel not in {"public-alpha", "production"}
        or not notary_profile
        or "\x00" in notary_profile
    ):
        raise DirectNotaryTransactionError(
            "release channel or Keychain profile is invalid"
        )
    if not app.is_dir() or app.is_symlink():
        raise DirectNotaryTransactionError(
            "prepared NeAntik.app is missing or unsafe"
        )
    transaction_root = Path(
        tempfile.mkdtemp(prefix=".neantik-notary.", dir=dist)
    )
    transaction_root.chmod(0o700)
    transaction_status = transaction_root.stat(follow_symlinks=False)
    transaction_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        transaction_flags |= os.O_NOFOLLOW
    transaction_descriptor = os.open(
        transaction_root,
        transaction_flags,
    )
    context: dict[str, Path] = {"transaction": transaction_root}
    hook = phase_hook or (lambda _phase, _context: None)
    try:
        inputs_root = transaction_root / "inputs"
        submitted_root = transaction_root / "submitted"
        precheck_root = transaction_root / "precheck"
        accepted_root = transaction_root / "accepted"
        final_root = transaction_root / "final"
        final_check_root = transaction_root / "final-check"
        for directory in (
            inputs_root,
            submitted_root,
            precheck_root,
            accepted_root,
            final_root,
            final_check_root,
        ):
            directory.mkdir(mode=0o700)
        inputs = snapshot_candidate_inputs(
            info_plist=project_root / "Resources" / "Info.plist",
            manifest=manifest,
            evidence=evidence,
            attestation=attestation,
            destination=inputs_root,
        )
        context["manifest"] = inputs.manifest.pinned
        context["evidence"] = inputs.evidence.pinned
        context["attestation"] = inputs.attestation.pinned
        context["info"] = inputs.info.pinned
        receipt_directory = dist / ".notary-receipts"
        ensure_private_receipt_directory(receipt_directory)
        version = read_version(inputs.info.pinned)
        archive_name = (
            f"NeAntik-{version}-arm64-notarized.zip"
        )
        download_url = os.environ.get(
            "NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL"
        )
        if download_url:
            validate_hosted_download_url(
                download_url,
                archive_name=archive_name,
            )
        archive_destination = dist / archive_name
        checksum_destination = dist / (archive_name + ".sha256")
        if (
            os.path.lexists(archive_destination)
            or os.path.lexists(checksum_destination)
        ):
            raise DirectNotaryTransactionError(
                "candidate archive or checksum exists; refusing overwrite"
            )
        hook("inputs-pinned", context)

        submitted = submitted_root / archive_name
        run_checked(
            [
                "ditto",
                "--norsrc",
                "-c",
                "-k",
                "--keepParent",
                str(app),
                str(submitted),
            ],
            cwd=project_root,
            runner=runner,
            label="submission ZIP packaging",
        )
        submitted.chmod(0o400)
        submitted_seal = TRANSACTION.seal_regular_file(
            submitted,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        context["submitted"] = submitted
        hook("submission-packaged", context)

        precheck_app = TRANSACTION.observe_sealed_phase(
            submitted_seal,
            lambda: extract_candidate_app(
                submitted,
                precheck_root,
                project_root=project_root,
                runner=runner,
            ),
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        context["precheck_app"] = precheck_app
        verify_candidate_app(
            precheck_app,
            project_root=project_root,
            inputs=inputs,
            release_channel=release_channel,
            runner=runner,
            full_preflight=True,
        )
        TRANSACTION.assert_sealed(
            submitted_seal,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        assert_candidate_inputs_unchanged(inputs)
        hook("submission-verified", context)

        def submit() -> str:
            return run_checked(
                [
                    "xcrun",
                    "notarytool",
                    "submit",
                    str(submitted),
                    "--keychain-profile",
                    notary_profile,
                    "--wait",
                    "--output-format",
                    "json",
                ],
                cwd=project_root,
                runner=runner,
                label="Apple notarization submission",
            )

        submit_output = TRANSACTION.observe_sealed_phase(
            submitted_seal,
            submit,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        submission_identifier = parse_notary_result(submit_output)
        info_output = run_checked(
            [
                "xcrun",
                "notarytool",
                "info",
                submission_identifier,
                "--keychain-profile",
                notary_profile,
                "--output-format",
                "json",
            ],
            cwd=project_root,
            runner=runner,
            label="Apple notarization status confirmation",
        )
        parse_notary_result(
            info_output,
            expected_identifier=submission_identifier,
        )
        TRANSACTION.assert_sealed(
            submitted_seal,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        context["submission_id"] = Path(submission_identifier)
        accepted_receipt = transaction_root / "apple-accepted.json"
        write_private_json(
            accepted_receipt,
            {
                "schemaVersion": 1,
                "releaseChannel": release_channel,
                "archiveName": archive_name,
                "appleSubmission": {
                    "id": submission_identifier,
                    "status": "Accepted",
                    "sha256": submitted_seal.sha256,
                    "size": submitted_seal.size,
                },
                "candidateInputs": {
                    "infoPlist": inputs.info.sha256,
                    "manifest": inputs.manifest.sha256,
                    "evidence": inputs.evidence.sha256,
                    "attestation": inputs.attestation.sha256,
                },
            },
        )
        accepted_receipt_destination = (
            receipt_directory
            / f"{archive_name}.{submission_identifier}.accepted.json"
        )
        publish_private_receipt(
            accepted_receipt,
            destination=accepted_receipt_destination,
        )
        hook("notary-accepted", context)

        staged_app = TRANSACTION.observe_sealed_phase(
            submitted_seal,
            lambda: extract_candidate_app(
                submitted,
                accepted_root,
                project_root=project_root,
                runner=runner,
            ),
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        context["staged_app"] = staged_app
        verify_candidate_app(
            staged_app,
            project_root=project_root,
            inputs=inputs,
            release_channel=release_channel,
            runner=runner,
            full_preflight=False,
        )
        run_checked(
            ["xcrun", "stapler", "staple", str(staged_app)],
            cwd=project_root,
            runner=runner,
            label="stapling accepted candidate",
        )
        run_checked(
            ["xcrun", "stapler", "validate", str(staged_app)],
            cwd=project_root,
            runner=runner,
            label="stapled ticket validation",
        )
        run_checked(
            [
                "spctl",
                "--assess",
                "--type",
                "execute",
                "--verbose=4",
                str(staged_app),
            ],
            cwd=project_root,
            runner=runner,
            label="Gatekeeper assessment",
        )
        verify_candidate_app(
            staged_app,
            project_root=project_root,
            inputs=inputs,
            release_channel=release_channel,
            runner=runner,
            full_preflight=False,
        )
        TRANSACTION.assert_sealed(
            submitted_seal,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        assert_candidate_inputs_unchanged(inputs)
        hook("staged-app-verified", context)

        final_archive = final_root / archive_name
        run_checked(
            [
                "ditto",
                "--norsrc",
                "-c",
                "-k",
                "--keepParent",
                str(staged_app),
                str(final_archive),
            ],
            cwd=project_root,
            runner=runner,
            label="final ZIP packaging",
        )
        final_archive.chmod(0o400)
        final_seal = TRANSACTION.seal_regular_file(
            final_archive,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        final_checksum = final_root / (archive_name + ".sha256")
        checksum_seal = TRANSACTION.write_checksum_sidecar(
            final_seal,
            final_checksum,
        )
        final_checksum.chmod(0o400)
        checksum_seal = TRANSACTION.seal_regular_file(
            final_checksum,
            maximum_bytes=4 * 1024,
        )
        context["final_archive"] = final_archive
        hook("final-packaged", context)

        def verify_final_archive() -> None:
            final_app = extract_candidate_app(
                final_archive,
                final_check_root,
                project_root=project_root,
                runner=runner,
            )
            verify_candidate_app(
                final_app,
                project_root=project_root,
                inputs=inputs,
                release_channel=release_channel,
                runner=runner,
                full_preflight=False,
            )
            run_checked(
                [
                    str(
                        project_root
                        / "scripts"
                        / "verify-direct-notarized-archive.py"
                    ),
                    "--project-root",
                    str(project_root),
                    "--archive",
                    str(final_archive),
                    "--expected-info-plist",
                    str(inputs.info.pinned),
                ],
                cwd=project_root,
                runner=runner,
                label="final notarized archive verification",
            )

        TRANSACTION.observe_sealed_phase(
            final_seal,
            verify_final_archive,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        TRANSACTION.assert_sealed(
            checksum_seal,
            maximum_bytes=4 * 1024,
        )
        TRANSACTION.assert_sealed(
            submitted_seal,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        assert_candidate_inputs_unchanged(inputs)
        hook("final-verified", context)

        receipt = transaction_root / "notary-receipt.json"
        write_private_json(
            receipt,
            {
                "schemaVersion": 1,
                "releaseChannel": release_channel,
                "archiveName": archive_name,
                "candidateInputs": {
                    "infoPlist": {
                        "sha256": inputs.info.sha256,
                        "size": inputs.info.size,
                    },
                    "manifest": {
                        "sha256": inputs.manifest.sha256,
                        "size": inputs.manifest.size,
                    },
                    "evidence": {
                        "sha256": inputs.evidence.sha256,
                        "size": inputs.evidence.size,
                    },
                    "attestation": {
                        "sha256": inputs.attestation.sha256,
                        "size": inputs.attestation.size,
                    },
                },
                "appleSubmission": {
                    "id": submission_identifier,
                    "status": "Accepted",
                    "sha256": submitted_seal.sha256,
                    "size": submitted_seal.size,
                },
                "finalArchive": {
                    "sha256": final_seal.sha256,
                    "size": final_seal.size,
                },
                "publicationState": "transaction-verified",
            },
        )
        receipt_destination = (
            receipt_directory
            / f"{archive_name}.{submission_identifier}.receipt.json"
        )
        publish_private_receipt(
            receipt,
            destination=receipt_destination,
        )
        TRANSACTION.publish_release_pair(
            final_seal,
            checksum_seal,
            archive_destination=archive_destination,
            checksum_destination=checksum_destination,
            maximum_archive_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        hook("published", context)
        return {
            "archive": str(archive_destination),
            "checksum": str(checksum_destination),
            "receipt": str(receipt_destination),
            "submissionId": submission_identifier,
            "sha256": final_seal.sha256,
        }
    except TRANSACTION.ReleaseTransactionError as error:
        raise DirectNotaryTransactionError(str(error)) from error
    except (
        OSError,
        zipfile.BadZipFile,
        SNAPSHOT.ReleaseInputSnapshotError,
    ) as error:
        raise DirectNotaryTransactionError(
            "Direct notarization transaction failed"
        ) from error
    finally:
        cleanup_exact_transaction(
            transaction_root,
            descriptor=transaction_descriptor,
            expected_device=transaction_status.st_dev,
            expected_inode=transaction_status.st_ino,
        )
        os.close(transaction_descriptor)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Notarize and publish one staged NeAntik Direct transaction."
        )
    )
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--attestation", type=Path, required=True)
    parser.add_argument(
        "--release-channel",
        choices=("public-alpha", "production"),
        required=True,
    )
    args = parser.parse_args()
    notary_profile = os.environ.get("NEANTIK_NOTARY_PROFILE", "")
    try:
        result = run_transaction(
            project_root=args.project_root,
            app=args.app,
            manifest=args.manifest,
            evidence=args.evidence,
            attestation=args.attestation,
            release_channel=args.release_channel,
            notary_profile=notary_profile,
        )
    except DirectNotaryTransactionError as error:
        print(f"Direct notarization failed: {error}", file=sys.stderr)
        return 1
    print("PASS: staged Direct notarization transaction verified.")
    print(f"Archive: {result['archive']}")
    print(f"Checksum: {result['checksum']}")
    print(f"Receipt: {result['receipt']}")
    print(f"SHA-256: {result['sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
