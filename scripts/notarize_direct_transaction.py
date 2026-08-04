#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import time
import uuid
import zipfile
from dataclasses import dataclass, replace
from pathlib import Path
from pathlib import PurePosixPath
from typing import Callable
from urllib.parse import unquote, urlparse

import release_input_snapshot as SNAPSHOT
import release_source_receipt as SOURCE
import release_transaction as TRANSACTION
import notary_transaction_state as STATE


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


@dataclass(frozen=True)
class TransactionRetirement:
    destination: Path | None
    moved: bool
    durable: bool
    verified: bool


def rebase_candidate_inputs(
    inputs: CandidateInputs,
    *,
    old_root: Path,
    new_root: Path,
) -> CandidateInputs:
    def rebase(
        snapshot: SNAPSHOT.ReleaseInputSnapshot,
    ) -> SNAPSHOT.ReleaseInputSnapshot:
        try:
            relative = snapshot.pinned.relative_to(old_root)
        except ValueError as error:
            raise DirectNotaryTransactionError(
                "pinned candidate input escapes the transaction"
            ) from error
        return replace(
            snapshot,
            pinned=new_root / relative,
        )

    return CandidateInputs(
        info=rebase(inputs.info),
        manifest=rebase(inputs.manifest),
        evidence=rebase(inputs.evidence),
        attestation=rebase(inputs.attestation),
    )


def receipt_candidate_inputs(
    inputs: CandidateInputs,
) -> dict[str, dict[str, object]]:
    return {
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
    }


CommandRunner = Callable[[list[str], Path], CommandResult]
PhaseHook = Callable[[str, dict[str, Path]], None]
SourceAssertion = Callable[[SOURCE.ReleaseSourceSnapshot], None]


def default_runner(command: list[str], cwd: Path) -> CommandResult:
    executable = Path(command[0])
    if (
        executable.is_absolute()
        and executable.suffix == ".py"
        and executable.parent == cwd / "scripts"
    ):
        command = [
            sys.executable,
            "-I",
            "-B",
            *command,
        ]
    environment = os.environ.copy()
    environment.pop("PYTHONPATH", None)
    environment.pop("PYTHONHOME", None)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["PYTHONNOUSERSITE"] = "1"
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30 * 60,
            env=environment,
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


def parse_notary_submission(output: str) -> str:
    try:
        payload = json.loads(
            output,
            object_pairs_hook=_reject_duplicate_json_pairs,
        )
    except (json.JSONDecodeError, TypeError) as error:
        raise DirectNotaryTransactionError(
            "Apple notary submission is not strict JSON"
        ) from error
    if not isinstance(payload, dict):
        raise DirectNotaryTransactionError(
            "Apple notary submission must be a JSON object"
        )
    identifier = payload.get("id")
    status_value = payload.get("status")
    if not isinstance(identifier, str):
        raise DirectNotaryTransactionError(
            "Apple notary submission is missing id"
        )
    if status_value is not None and not isinstance(status_value, str):
        raise DirectNotaryTransactionError(
            "Apple notary submission status is invalid"
        )
    try:
        canonical_identifier = str(uuid.UUID(identifier))
    except ValueError as error:
        raise DirectNotaryTransactionError(
            "Apple notary submission contains an invalid id"
        ) from error
    if identifier != canonical_identifier:
        raise DirectNotaryTransactionError(
            "Apple notary submission id is not canonical"
        )
    if (
        status_value is not None
        and status_value not in {"Accepted", "In Progress"}
    ):
        raise DirectNotaryTransactionError(
            f"Apple notarization submission status is {status_value}"
        )
    return identifier


def find_notary_submission_in_history_or_none(
    output: str,
    *,
    submission_name: str,
) -> tuple[str | None, str]:
    try:
        payload = json.loads(
            output,
            object_pairs_hook=_reject_duplicate_json_pairs,
        )
    except (json.JSONDecodeError, TypeError) as error:
        raise DirectNotaryTransactionError(
            "Apple notary history is not strict JSON"
        ) from error

    def walk(value: object) -> str | None:
        if isinstance(value, dict):
            identifier = value.get("id")
            name = value.get("name") or value.get("submissionName")
            if name == submission_name and isinstance(identifier, str):
                try:
                    canonical_identifier = str(uuid.UUID(identifier))
                except ValueError as error:
                    raise DirectNotaryTransactionError(
                        "Apple notary history contains an invalid id"
                    ) from error
                if identifier != canonical_identifier:
                    raise DirectNotaryTransactionError(
                        "Apple notary history id is not canonical"
                    )
                return identifier
            for child in value.values():
                found = walk(child)
                if found is not None:
                    return found
        elif isinstance(value, list):
            for child in value:
                found = walk(child)
                if found is not None:
                    return found
        return None

    found = walk(payload)
    return found, hashlib.sha256(output.encode("utf-8")).hexdigest()


def find_notary_submission_in_history(
    output: str,
    *,
    submission_name: str,
) -> str:
    found, _history_sha256 = find_notary_submission_in_history_or_none(
        output,
        submission_name=submission_name,
    )
    if found is None:
        raise DirectNotaryTransactionError(
            "Apple submission effect is unknown and notary history does "
            "not contain the retained submission name"
        )
    return found


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
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")
    parent_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        parent_flags |= os.O_NOFOLLOW
    try:
        parent = os.open(path.parent, parent_flags)
    except OSError as error:
        raise DirectNotaryTransactionError(
            "notary receipt output is unavailable"
        ) from error
    parent_status = os.fstat(parent)
    if (
        not stat.S_ISDIR(parent_status.st_mode)
        or parent_status.st_uid != os.geteuid()
        or parent_status.st_mode & 0o077
    ):
        os.close(parent)
        raise DirectNotaryTransactionError(
            "notary receipt directory is unsafe"
        )
    temporary_name = f".{path.name}.tmp-{uuid.uuid4().hex}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(
            temporary_name,
            flags,
            0o600,
            dir_fd=parent,
        )
    except OSError as error:
        os.close(parent)
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
        os.fchmod(descriptor, 0o400)
        os.fsync(descriptor)
        created = os.fstat(descriptor)
        if (
            not stat.S_ISREG(created.st_mode)
            or created.st_uid != os.geteuid()
            or created.st_nlink != 1
            or stat.S_IMODE(created.st_mode) != 0o400
            or created.st_size != len(encoded)
        ):
            raise DirectNotaryTransactionError(
                "notary receipt write failed"
            )
        TRANSACTION._rename_exclusive(
            parent,
            temporary_name,
            parent,
            path.name,
        )
        os.fsync(parent)
        succeeded = True
    except OSError as error:
        raise DirectNotaryTransactionError(
            "notary receipt write failed"
        ) from error
    finally:
        try:
            os.close(descriptor)
        finally:
            os.close(parent)
        # The canonical final name is never visible until the complete,
        # fsynced file is committed. A failed temporary file remains only in
        # the private transaction directory for descriptor cleanup.


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


_INITIAL_TRANSACTION_PATTERN = re.compile(
    r"^\.neantik-notary-init\."
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)


def create_initial_transaction_root(
    dist: Path,
) -> tuple[Path, int, int, int, str, os.stat_result]:
    coordinator = STATE.acquire_transaction_lock(
        dist / ".notary-locks",
        "initialization",
    )
    root_descriptor = -1
    lease_descriptor = -1
    dist_descriptor = -1
    root_status: os.stat_result | None = None
    root: Path | None = None
    try:
        dist_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            dist_flags |= os.O_NOFOLLOW
        dist_descriptor = os.open(dist, dist_flags)
        unfinished = sorted(
            name
            for name in os.listdir(dist_descriptor)
            if name.startswith(".neantik-notary-init.")
        )
        if unfinished:
            raise DirectNotaryTransactionError(
                "unfinished pre-activation notary transaction requires "
                "operator reconciliation"
            )
        transaction_id = str(uuid.uuid4())
        name = f".neantik-notary-init.{transaction_id}"
        if not _INITIAL_TRANSACTION_PATTERN.fullmatch(name):
            raise DirectNotaryTransactionError(
                "initial notary transaction identifier is invalid"
            )
        root = dist / name
        os.mkdir(name, 0o700, dir_fd=dist_descriptor)
        root_status = os.stat(
            name,
            dir_fd=dist_descriptor,
            follow_symlinks=False,
        )
        root_descriptor = os.open(
            name,
            dist_flags,
            dir_fd=dist_descriptor,
        )
        opened_root_status = os.fstat(root_descriptor)
        dist_status = os.fstat(dist_descriptor)
        if (
            not stat.S_ISDIR(opened_root_status.st_mode)
            or opened_root_status.st_uid != os.geteuid()
            or stat.S_IMODE(opened_root_status.st_mode) != 0o700
            or opened_root_status.st_dev != dist_status.st_dev
            or opened_root_status.st_dev != root_status.st_dev
            or opened_root_status.st_ino != root_status.st_ino
        ):
            raise DirectNotaryTransactionError(
                "initial notary transaction directory is unsafe"
            )
        lease_flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            lease_flags |= os.O_NOFOLLOW
        lease_descriptor = os.open(
            ".init-lease",
            lease_flags,
            0o600,
            dir_fd=root_descriptor,
        )
        lease_status = os.fstat(lease_descriptor)
        if (
            not stat.S_ISREG(lease_status.st_mode)
            or lease_status.st_uid != os.geteuid()
            or lease_status.st_nlink != 1
            or stat.S_IMODE(lease_status.st_mode) != 0o600
        ):
            raise DirectNotaryTransactionError(
                "initial notary transaction lease is unsafe"
            )
        fcntl.flock(lease_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        root_status = opened_root_status
        write_private_json(
            root / ".init-marker.json",
            {
                "activeTarget": f".neantik-notary.{transaction_id}",
                "createdAtUnixNs": time.time_ns(),
                "directoryName": name,
                "externalEffectsAllowed": False,
                "markerType": "neantik-notary-initialization",
                "schemaVersion": 1,
                "transactionId": transaction_id,
            },
        )
        os.fsync(root_descriptor)
        os.fsync(dist_descriptor)
        os.close(dist_descriptor)
        dist_descriptor = -1
        return (
            root,
            root_descriptor,
            lease_descriptor,
            coordinator,
            transaction_id,
            root_status,
        )
    except Exception:
        if (
            root is not None
            and root_status is not None
            and root_descriptor < 0
            and dist_descriptor >= 0
        ):
            try:
                retry_flags = (
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                )
                if hasattr(os, "O_NOFOLLOW"):
                    retry_flags |= os.O_NOFOLLOW
                root_descriptor = os.open(
                    root.name,
                    retry_flags,
                    dir_fd=dist_descriptor,
                )
            except OSError:
                pass
        if root is not None and root_status is not None:
            try:
                retire_exact_transaction(
                    root,
                    descriptor=root_descriptor,
                    expected_device=root_status.st_dev,
                    expected_inode=root_status.st_ino,
                )
            except Exception:
                pass
        for opened in (
            lease_descriptor,
            root_descriptor,
            dist_descriptor,
            coordinator,
        ):
            if opened >= 0:
                try:
                    os.close(opened)
                except OSError:
                    pass
        raise


def retire_exact_transaction(
    path: Path,
    *,
    descriptor: int,
    expected_device: int,
    expected_inode: int,
) -> TransactionRetirement:
    """Move an exact transaction aside without deleting any discovered path.

    Darwin has no unlink-by-file-descriptor primitive. A stat-then-unlink
    cleanup can therefore delete a same-user replacement. Retirement uses an
    exclusive same-filesystem rename, verifies the moved inode through a new
    no-follow descriptor, and deliberately leaves recursive deletion to an
    explicit operator-reviewed maintenance action.
    """
    try:
        status = os.fstat(descriptor)
    except OSError:
        return TransactionRetirement(None, False, False, False)
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_dev != expected_device
        or status.st_ino != expected_inode
    ):
        return TransactionRetirement(None, False, False, False)
    retired_root = path.parent / ".notary-retired"
    try:
        STATE.ensure_private_directory(retired_root)
    except (OSError, STATE.NotaryTransactionStateError):
        return TransactionRetirement(None, False, False, False)
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    source_parent = -1
    retired_parent = -1
    moved_descriptor = -1
    destination = retired_root / str(uuid.uuid4())
    moved = False
    durable = False
    verified = False
    try:
        source_parent = os.open(path.parent, directory_flags)
        retired_parent = os.open(retired_root, directory_flags)
        current = os.stat(
            path.name,
            dir_fd=source_parent,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(current.st_mode)
            or current.st_dev != expected_device
            or current.st_ino != expected_inode
        ):
            return TransactionRetirement(None, False, False, False)
        TRANSACTION._rename_exclusive(
            source_parent,
            path.name,
            retired_parent,
            destination.name,
        )
        moved = True
        try:
            os.fsync(source_parent)
            os.fsync(retired_parent)
            durable = True
        except OSError:
            return TransactionRetirement(
                destination,
                moved,
                durable,
                verified,
            )
        moved_descriptor = os.open(
            destination.name,
            directory_flags,
            dir_fd=retired_parent,
        )
        moved_status = os.fstat(moved_descriptor)
        verified = (
            stat.S_ISDIR(moved_status.st_mode)
            and moved_status.st_dev == expected_device
            and moved_status.st_ino == expected_inode
        )
        if not verified:
            return TransactionRetirement(
                destination,
                moved,
                durable,
                verified,
            )
        return TransactionRetirement(
            destination,
            moved,
            durable,
            verified,
        )
    except (OSError, TRANSACTION.ReleaseTransactionError):
        return TransactionRetirement(
            destination if moved else None,
            moved,
            durable,
            verified,
        )
    finally:
        for opened in (
            moved_descriptor,
            retired_parent,
            source_parent,
        ):
            if opened >= 0:
                try:
                    os.close(opened)
                except OSError:
                    pass


def _canonical_private_json(payload: dict[str, object]) -> bytes:
    return (
        json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def _read_private_regular_file(
    path: Path,
    *,
    maximum_bytes: int,
) -> bytes:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise DirectNotaryTransactionError(
            "private transaction file is unavailable"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) not in {0o400, 0o600}
            or before.st_size <= 0
            or before.st_size > maximum_bytes
        ):
            raise DirectNotaryTransactionError(
                "private transaction file is unsafe"
            )
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise DirectNotaryTransactionError(
                    "private transaction file exceeds its size limit"
                )
            chunks.append(chunk)
        contents = b"".join(chunks)
        after = os.fstat(descriptor)
    except OSError as error:
        raise DirectNotaryTransactionError(
            "private transaction file could not be read"
        ) from error
    finally:
        os.close(descriptor)
    if (
        len(contents) != before.st_size
        or before.st_dev != after.st_dev
        or before.st_ino != after.st_ino
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
    ):
        raise DirectNotaryTransactionError(
            "private transaction file changed while reading"
        )
    return contents


def ensure_private_json_receipt(
    source: Path,
    *,
    payload: dict[str, object],
    destination: Path,
) -> None:
    expected = _canonical_private_json(payload)
    if os.path.lexists(source):
        if (
            _read_private_regular_file(
                source,
                maximum_bytes=1024 * 1024,
            )
            != expected
        ):
            raise DirectNotaryTransactionError(
                "private notary receipt does not match durable state"
            )
    else:
        write_private_json(source, payload)
    if os.path.lexists(destination):
        if (
            _read_private_regular_file(
                destination,
                maximum_bytes=1024 * 1024,
            )
            != expected
        ):
            raise DirectNotaryTransactionError(
                "published private notary receipt does not match state"
            )
    else:
        publish_private_receipt(source, destination=destination)


def _receipt_data(
    receipts: tuple[STATE.StateReceipt, ...],
    stage: str,
) -> dict[str, object]:
    matching = [
        receipt.payload["data"]
        for receipt in receipts
        if receipt.stage == stage
    ]
    if len(matching) != 1 or not isinstance(matching[0], dict):
        raise DirectNotaryTransactionError(
            f"durable transaction state {stage} is missing"
        )
    return matching[0]


def _transaction_matches_current_release(
    receipts: tuple[STATE.StateReceipt, ...],
    *,
    archive_name: str,
    inputs: CandidateInputs,
    release_source: SOURCE.ReleaseSourceSnapshot,
    runtime_build_evidence: dict[str, object],
    release_channel: str,
) -> bool:
    created = _receipt_data(receipts, "transaction-created")
    return (
        created.get("archiveName") == archive_name
        and created.get("releaseChannel") == release_channel
        and created.get("candidateInputs")
        == {
            "infoPlist": inputs.info.sha256,
            "manifest": inputs.manifest.sha256,
            "evidence": inputs.evidence.sha256,
            "attestation": inputs.attestation.sha256,
        }
        and created.get("releaseSource") == release_source.payload
        and created.get("runtimeBuildEvidence")
        == runtime_build_evidence
    )


def _validate_reconciliation_marker(
    marker: Path,
    *,
    transaction_id: str,
    archive_name: str,
    submission_name: str,
) -> None:
    try:
        raw = _read_private_regular_file(
            marker,
            maximum_bytes=16 * 1024,
        )
        payload = json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_json_pairs,
        )
    except (json.JSONDecodeError, TypeError) as error:
        raise DirectNotaryTransactionError(
            "notary reconciliation marker is invalid"
        ) from error
    if (
        not isinstance(payload, dict)
        or _canonical_private_json(payload) != raw
        or set(payload)
        != {
            "archiveName",
            "checkedAtUnixNs",
            "historySHA256",
            "markerType",
            "result",
            "schemaVersion",
            "submissionNameSHA256",
            "transactionId",
        }
        or payload.get("schemaVersion") != 1
        or payload.get("markerType")
        != "neantik-notary-reconciliation"
        or payload.get("result") != "submission-absent"
        or payload.get("transactionId") != transaction_id
        or payload.get("archiveName") != archive_name
        or not isinstance(payload.get("checkedAtUnixNs"), int)
        or isinstance(payload.get("checkedAtUnixNs"), bool)
        or int(payload["checkedAtUnixNs"]) <= 0
        or not isinstance(payload.get("historySHA256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", payload["historySHA256"])
        is None
        or payload.get("submissionNameSHA256")
        != hashlib.sha256(submission_name.encode("utf-8")).hexdigest()
    ):
        raise DirectNotaryTransactionError(
            "notary reconciliation marker is invalid"
        )


def reconcile_mismatched_submit_intent(
    active: tuple[Path, tuple[STATE.StateReceipt, ...]],
    *,
    project_root: Path,
    notary_profile: str,
    runner: CommandRunner,
) -> bool:
    """Prove a stale submit intent had no Apple effect, then retain it.

    The durable submit-intent receipt is written before invoking Apple. If the
    invocation fails before returning an id, a later clean source commit must
    not silently reuse that candidate. A strict history query is the only
    automatic no-effect proof: a matching name remains blocking, while an
    absent name is recorded inside the exact transaction before inode-verified
    retirement.
    """
    transaction_root, receipts = active
    if receipts[-1].stage != "submit-intent":
        return False
    created = _receipt_data(receipts, "transaction-created")
    submission_name = created.get("submissionName")
    archive_name = created.get("archiveName")
    transaction_id = receipts[0].payload.get("transactionId")
    if (
        not isinstance(submission_name, str)
        or not isinstance(archive_name, str)
        or not isinstance(transaction_id, str)
    ):
        raise DirectNotaryTransactionError(
            "stale submit-intent transaction identity is invalid"
        )
    history_output = run_checked(
        [
            "xcrun",
            "notarytool",
            "history",
            "--keychain-profile",
            notary_profile,
            "--output-format",
            "json",
        ],
        cwd=project_root,
        runner=runner,
        label="stale Apple notarization history reconciliation",
    )
    found, history_sha256 = find_notary_submission_in_history_or_none(
        history_output,
        submission_name=submission_name,
    )
    if found is not None:
        raise DirectNotaryTransactionError(
            "stale transaction has a matching Apple submission and "
            "requires exact-source recovery"
        )

    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(transaction_root, directory_flags)
        before = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(before.st_mode)
            or before.st_uid != os.geteuid()
            or stat.S_IMODE(before.st_mode) != 0o700
        ):
            raise DirectNotaryTransactionError(
                "stale submit-intent transaction directory is unsafe"
        )
        marker = transaction_root / "notary-reconciliation.json"
        if os.path.lexists(marker):
            _validate_reconciliation_marker(
                marker,
                transaction_id=transaction_id,
                archive_name=archive_name,
                submission_name=submission_name,
            )
        else:
            write_private_json(
                marker,
                {
                    "archiveName": archive_name,
                    "checkedAtUnixNs": time.time_ns(),
                    "historySHA256": history_sha256,
                    "markerType": "neantik-notary-reconciliation",
                    "result": "submission-absent",
                    "schemaVersion": 1,
                    "submissionNameSHA256": hashlib.sha256(
                        submission_name.encode("utf-8")
                    ).hexdigest(),
                    "transactionId": transaction_id,
                },
            )
            _validate_reconciliation_marker(
                marker,
                transaction_id=transaction_id,
                archive_name=archive_name,
                submission_name=submission_name,
            )
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_uid != after.st_uid
            or before.st_mode != after.st_mode
        ):
            raise DirectNotaryTransactionError(
                "stale submit-intent transaction changed during "
                "reconciliation"
            )
        retirement = retire_exact_transaction(
            transaction_root,
            descriptor=descriptor,
            expected_device=before.st_dev,
            expected_inode=before.st_ino,
        )
        if not (
            retirement.moved
            and retirement.durable
            and retirement.verified
        ):
            raise DirectNotaryTransactionError(
                "reconciled stale transaction could not be safely retired"
            )
        return True
    except OSError as error:
        raise DirectNotaryTransactionError(
            "stale submit-intent transaction could not be reconciled"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def observe_public_release_pair(
    archive: TRANSACTION.FileSeal,
    checksum: TRANSACTION.FileSeal,
    action: Callable[[], object],
) -> object:
    return TRANSACTION.observe_sealed_phase(
        archive,
        lambda: TRANSACTION.observe_sealed_phase(
            checksum,
            action,
            maximum_bytes=4 * 1024,
            allowed_link_counts=frozenset({2}),
        ),
        maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        allowed_link_counts=frozenset({2}),
    )


def resume_known_transaction(
    active: tuple[Path, tuple[STATE.StateReceipt, ...]],
    *,
    project_root: Path,
    dist: Path,
    archive_name: str,
    inputs: CandidateInputs,
    release_source: SOURCE.ReleaseSourceSnapshot,
    runtime_build_evidence: dict[str, object],
    release_channel: str,
    notary_profile: str,
    runner: CommandRunner,
    hook: PhaseHook,
    source_assertion: SourceAssertion,
) -> dict[str, str]:
    transaction_root, receipts = active
    latest = receipts[-1].stage
    stage_index = {
        stage: index
        for index, (_prefix, stage) in enumerate(STATE.STAGES)
    }
    if latest in {"transaction-created", "submission-ready"}:
        raise DirectNotaryTransactionError(
            "unfinished pre-submission transaction requires "
            "operator cleanup"
        )
    created = _receipt_data(receipts, "transaction-created")
    if not _transaction_matches_current_release(
        receipts,
        archive_name=archive_name,
        inputs=inputs,
        release_source=release_source,
        runtime_build_evidence=runtime_build_evidence,
        release_channel=release_channel,
    ):
        raise DirectNotaryTransactionError(
            "unfinished transaction does not match the exact current "
            "candidate and release source"
        )
    submission_ready = _receipt_data(receipts, "submission-ready")
    submitted_relative = submission_ready.get("relativePath")
    if (
        not isinstance(submitted_relative, str)
        or Path(submitted_relative).is_absolute()
        or ".." in Path(submitted_relative).parts
    ):
        raise DirectNotaryTransactionError(
            "durable submitted archive path is invalid"
        )
    submitted = transaction_root / submitted_relative
    submitted_seal = TRANSACTION.seal_regular_file(
        submitted,
        maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
    )
    if (
        submission_ready.get("sha256") != submitted_seal.sha256
        or submission_ready.get("size") != submitted_seal.size
    ):
        raise DirectNotaryTransactionError(
            "retained Apple submission archive does not match state"
        )
    state_store = STATE.StateStore(
        transaction_root,
        str(receipts[0].payload["transactionId"]),
    )
    source_assertion(release_source)
    assert_candidate_inputs_unchanged(inputs)

    if latest == "submit-intent":
        history_output = run_checked(
            [
                "xcrun",
                "notarytool",
                "history",
                "--keychain-profile",
                notary_profile,
                "--output-format",
                "json",
            ],
            cwd=project_root,
            runner=runner,
            label="Apple notarization history reconciliation",
        )
        submission_identifier = find_notary_submission_in_history(
            history_output,
            submission_name=created["submissionName"],
        )
        state_store.commit(
            "submission-known",
            {
                "id": submission_identifier,
                "submissionName": created["submissionName"],
                "sha256": submitted_seal.sha256,
                "size": submitted_seal.size,
            },
        )
        resumed = STATE.find_active_transaction(dist, archive_name)
        if resumed is None:
            raise DirectNotaryTransactionError(
                "reconciled Apple submission state is unavailable"
            )
        return resume_known_transaction(
            resumed,
            project_root=project_root,
            dist=dist,
            archive_name=archive_name,
            inputs=inputs,
            release_source=release_source,
            runtime_build_evidence=runtime_build_evidence,
            release_channel=release_channel,
            notary_profile=notary_profile,
            runner=runner,
            hook=hook,
            source_assertion=source_assertion,
        )

    if latest == "submission-known":
        known = _receipt_data(receipts, "submission-known")
        submission_identifier = known.get("id")
        if not isinstance(submission_identifier, str):
            raise DirectNotaryTransactionError(
                "durable Apple submission id is invalid"
            )
        wait_output = TRANSACTION.observe_sealed_phase(
            submitted_seal,
            lambda: run_checked(
                [
                    "xcrun",
                    "notarytool",
                    "wait",
                    submission_identifier,
                    "--keychain-profile",
                    notary_profile,
                    "--timeout",
                    "30m",
                    "--output-format",
                    "json",
                ],
                cwd=project_root,
                runner=runner,
                label="Apple notarization recovery wait",
            ),
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        parse_notary_result(
            wait_output,
            expected_identifier=submission_identifier,
        )
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
            label="Apple notarization recovery confirmation",
        )
        parse_notary_result(
            info_output,
            expected_identifier=submission_identifier,
        )
        state_store.commit(
            "accepted",
            {
                "id": submission_identifier,
                "submissionName": known["submissionName"],
                "sha256": submitted_seal.sha256,
                "size": submitted_seal.size,
            },
        )
        receipts = state_store.load()
        latest = receipts[-1].stage
    else:
        accepted = _receipt_data(receipts, "accepted")
        submission_identifier = accepted.get("id")
        if not isinstance(submission_identifier, str):
            raise DirectNotaryTransactionError(
                "durable Accepted submission id is invalid"
            )
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
            label="Apple Accepted recovery confirmation",
        )
        parse_notary_result(
            info_output,
            expected_identifier=submission_identifier,
        )

    accepted_payload: dict[str, object] = {
        "schemaVersion": 2,
        "receiptType": "apple-accepted",
        "releaseChannel": release_channel,
        "archiveName": archive_name,
        "releaseSource": release_source.payload,
        "runtimeBuildEvidence": runtime_build_evidence,
        "appleSubmission": {
            "id": submission_identifier,
            "status": "Accepted",
            "sha256": submitted_seal.sha256,
            "size": submitted_seal.size,
        },
        "candidateInputs": receipt_candidate_inputs(inputs),
    }
    receipt_directory = dist / ".notary-receipts"
    ensure_private_receipt_directory(receipt_directory)
    accepted_destination = (
        receipt_directory
        / f"{archive_name}.{submission_identifier}.accepted.json"
    )
    ensure_private_json_receipt(
        transaction_root / "apple-accepted.json",
        payload=accepted_payload,
        destination=accepted_destination,
    )

    if stage_index[latest] < stage_index["final-verified"]:
        retry_root = transaction_root / f"resume-{uuid.uuid4().hex}"
        accepted_root = retry_root / "accepted"
        final_root = retry_root / "final"
        final_check_root = retry_root / "final-check"
        for directory in (
            retry_root,
            accepted_root,
            final_root,
            final_check_root,
        ):
            directory.mkdir(mode=0o700)
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
            label="recovery stapling accepted candidate",
        )
        run_checked(
            ["xcrun", "stapler", "validate", str(staged_app)],
            cwd=project_root,
            runner=runner,
            label="recovery stapled ticket validation",
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
            label="recovery Gatekeeper assessment",
        )
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
            label="recovery final ZIP packaging",
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
            label="recovery final notarized archive verification",
        )
        state_store.commit(
            "final-verified",
            {
                "archiveName": archive_name,
                "archiveRelativePath": str(
                    final_archive.relative_to(transaction_root)
                ),
                "checksumRelativePath": str(
                    final_checksum.relative_to(transaction_root)
                ),
                "sha256": final_seal.sha256,
                "size": final_seal.size,
                "checksumSHA256": checksum_seal.sha256,
                "checksumSize": checksum_seal.size,
            },
        )
        receipts = state_store.load()
        latest = receipts[-1].stage
    final_state = _receipt_data(receipts, "final-verified")
    archive_relative = final_state.get("archiveRelativePath")
    checksum_relative = final_state.get("checksumRelativePath")
    if not isinstance(archive_relative, str) or not isinstance(
        checksum_relative,
        str,
    ):
        raise DirectNotaryTransactionError(
            "durable final artifact paths are invalid"
        )
    for relative in (archive_relative, checksum_relative):
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise DirectNotaryTransactionError(
                "durable final artifact path escapes the transaction"
            )
    final_archive = transaction_root / archive_relative
    final_checksum = transaction_root / checksum_relative
    final_seal = TRANSACTION.seal_regular_file(
        final_archive,
        maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        allowed_link_counts=frozenset({1, 2}),
    )
    checksum_seal = TRANSACTION.seal_regular_file(
        final_checksum,
        maximum_bytes=4 * 1024,
        allowed_link_counts=frozenset({1, 2}),
    )
    if (
        final_state.get("sha256") != final_seal.sha256
        or final_state.get("size") != final_seal.size
        or final_state.get("checksumSHA256") != checksum_seal.sha256
        or final_state.get("checksumSize") != checksum_seal.size
    ):
        raise DirectNotaryTransactionError(
            "retained final artifacts do not match durable state"
        )
    TRANSACTION.assert_checksum_matches_archive(
        final_seal,
        checksum_seal,
    )
    final_receipt_payload: dict[str, object] = {
        "schemaVersion": 2,
        "receiptType": "direct-release",
        "releaseChannel": release_channel,
        "archiveName": archive_name,
        "releaseSource": release_source.payload,
        "runtimeBuildEvidence": runtime_build_evidence,
        "candidateInputs": receipt_candidate_inputs(inputs),
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
    }
    final_receipt_destination = (
        receipt_directory
        / f"{archive_name}.{submission_identifier}.receipt.json"
    )
    ensure_private_json_receipt(
        transaction_root / "notary-receipt.json",
        payload=final_receipt_payload,
        destination=final_receipt_destination,
    )
    archive_destination = dist / archive_name
    checksum_destination = dist / (archive_name + ".sha256")
    TRANSACTION.publish_or_adopt_sealed_file(
        checksum_seal,
        destination=checksum_destination,
        maximum_bytes=4 * 1024,
    )
    public_checksum_seal = TRANSACTION.seal_regular_file(
        checksum_destination,
        maximum_bytes=4 * 1024,
        allowed_link_counts=frozenset({2}),
    )
    if stage_index[latest] < stage_index["sidecar-committed"]:
        def commit_recovered_sidecar() -> None:
            hook(
                "sidecar-recovered",
                {"transaction": transaction_root},
            )
            state_store.commit(
                "sidecar-committed",
                {
                    "name": checksum_destination.name,
                    "sha256": checksum_seal.sha256,
                    "size": checksum_seal.size,
                },
            )

        TRANSACTION.observe_sealed_phase(
            public_checksum_seal,
            commit_recovered_sidecar,
            maximum_bytes=4 * 1024,
            allowed_link_counts=frozenset({2}),
        )
        receipts = state_store.load()
        latest = receipts[-1].stage
    TRANSACTION.publish_or_adopt_sealed_file(
        final_seal,
        destination=archive_destination,
        maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
    )
    public_archive_seal = TRANSACTION.seal_regular_file(
        archive_destination,
        maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        allowed_link_counts=frozenset({2}),
    )
    if stage_index[latest] < stage_index["zip-committed"]:
        def commit_recovered_archive() -> None:
            hook(
                "archive-recovered",
                {"transaction": transaction_root},
            )
            state_store.commit(
                "zip-committed",
                {
                    "name": archive_destination.name,
                    "sha256": final_seal.sha256,
                    "size": final_seal.size,
                },
            )

        TRANSACTION.observe_sealed_phase(
            public_archive_seal,
            commit_recovered_archive,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
            allowed_link_counts=frozenset({2}),
        )
        receipts = state_store.load()
        latest = receipts[-1].stage
    def verify_recovered_publication() -> None:
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
                str(archive_destination),
                "--expected-info-plist",
                str(inputs.info.pinned),
            ],
            cwd=project_root,
            runner=runner,
            label="recovered public archive verification",
        )
        TRANSACTION.assert_checksum_matches_archive(
            public_archive_seal,
            public_checksum_seal,
        )
        source_assertion(release_source)
        assert_candidate_inputs_unchanged(inputs)
        if stage_index[latest] < stage_index["publication-complete"]:
            state_store.commit(
                "publication-complete",
                {
                    "archiveName": archive_name,
                    "archiveRelativePath": str(
                        final_archive.relative_to(transaction_root)
                    ),
                    "checksumRelativePath": str(
                        final_checksum.relative_to(transaction_root)
                    ),
                    "sha256": final_seal.sha256,
                    "receipt": final_receipt_destination.name,
                },
            )
        hook(
            "recovery-published",
            {"transaction": transaction_root},
        )

    observe_public_release_pair(
        public_archive_seal,
        public_checksum_seal,
        verify_recovered_publication,
    )
    TRANSACTION.assert_sealed(
        public_archive_seal,
        maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        allowed_link_counts=frozenset({2}),
    )
    TRANSACTION.assert_sealed(
        public_checksum_seal,
        maximum_bytes=4 * 1024,
        allowed_link_counts=frozenset({2}),
    )
    transaction_status = transaction_root.stat(follow_symlinks=False)
    transaction_descriptor = os.open(
        transaction_root,
        os.O_RDONLY
        | os.O_DIRECTORY
        | os.O_CLOEXEC
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        retirement = retire_exact_transaction(
            transaction_root,
            descriptor=transaction_descriptor,
            expected_device=transaction_status.st_dev,
            expected_inode=transaction_status.st_ino,
        )
        if not retirement.verified or not retirement.durable:
            raise DirectNotaryTransactionError(
                "completed notary transaction could not be safely retired"
            )
    finally:
        os.close(transaction_descriptor)
    return {
        "archive": str(archive_destination),
        "checksum": str(checksum_destination),
        "receipt": str(final_receipt_destination),
        "submissionId": submission_identifier,
        "sha256": final_seal.sha256,
    }


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
    source_snapshot: SOURCE.ReleaseSourceSnapshot | None = None,
    source_assertion: SourceAssertion = SOURCE.assert_release_source_unchanged,
    runtime_build_evidence: dict[str, object] | None = None,
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
    (
        transaction_root,
        transaction_descriptor,
        initialization_lease_descriptor,
        initialization_coordinator_descriptor,
        transaction_id,
        transaction_status,
    ) = create_initial_transaction_root(dist)
    context: dict[str, Path] = {"transaction": transaction_root}
    hook = phase_hook or (lambda _phase, _context: None)
    lock_descriptor = -1
    preserve_transaction = False
    transaction_complete = False
    state_store: STATE.StateStore | None = None
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
        release_source = (
            source_snapshot
            if source_snapshot is not None
            else SOURCE.capture_release_source(project_root)
        )
        if release_source.project_root.resolve() != project_root:
            raise DirectNotaryTransactionError(
                "release source snapshot belongs to another worktree"
            )
        source_assertion(release_source)
        bound_runtime_build_evidence = (
            runtime_build_evidence
            if runtime_build_evidence is not None
            else SOURCE.runtime_build_evidence_from_manifest(
                release_source,
                inputs.manifest.pinned,
            )
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
        lock_descriptor = STATE.acquire_transaction_lock(
            dist / ".notary-locks",
            archive_name,
        )
        download_url = os.environ.get(
            "NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL"
        )
        if download_url:
            validate_hosted_download_url(
                download_url,
                archive_name=archive_name,
            )
        active = STATE.find_active_transaction(
            dist,
            archive_name,
            exclude=transaction_root,
        )
        if active is not None:
            if (
                not _transaction_matches_current_release(
                    active[1],
                    archive_name=archive_name,
                    inputs=inputs,
                    release_source=release_source,
                    runtime_build_evidence=bound_runtime_build_evidence,
                    release_channel=release_channel,
                )
                and reconcile_mismatched_submit_intent(
                    active,
                    project_root=project_root,
                    notary_profile=notary_profile,
                    runner=runner,
                )
            ):
                active = None
        if active is not None:
            resumed = resume_known_transaction(
                active,
                project_root=project_root,
                dist=dist,
                archive_name=archive_name,
                inputs=inputs,
                release_source=release_source,
                runtime_build_evidence=bound_runtime_build_evidence,
                release_channel=release_channel,
                notary_profile=notary_profile,
                runner=runner,
                hook=hook,
                source_assertion=source_assertion,
            )
            transaction_complete = True
            return resumed
        state_store = STATE.StateStore(
            transaction_root,
            transaction_id,
        )
        submission_name = f"{transaction_id}-{archive_name}"
        state_store.commit(
            "transaction-created",
            {
                "archiveName": archive_name,
                "submissionName": submission_name,
                "releaseChannel": release_channel,
                "candidateInputs": {
                    "infoPlist": inputs.info.sha256,
                    "manifest": inputs.manifest.sha256,
                    "evidence": inputs.evidence.sha256,
                    "attestation": inputs.attestation.sha256,
                },
                "releaseSource": release_source.payload,
                "runtimeBuildEvidence": bound_runtime_build_evidence,
            },
        )
        initial_root = transaction_root
        active_root = dist / f".neantik-notary.{transaction_id}"
        hook("before-activation", context)
        dist_descriptor = os.open(
            dist,
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            TRANSACTION._rename_exclusive(
                dist_descriptor,
                initial_root.name,
                dist_descriptor,
                active_root.name,
            )
            transaction_root = active_root
            active_descriptor = os.open(
                active_root.name,
                os.O_RDONLY
                | os.O_DIRECTORY
                | os.O_CLOEXEC
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=dist_descriptor,
            )
            try:
                active_status = os.fstat(active_descriptor)
                if (
                    not stat.S_ISDIR(active_status.st_mode)
                    or active_status.st_dev != transaction_status.st_dev
                    or active_status.st_ino != transaction_status.st_ino
                    or active_status.st_uid != os.geteuid()
                    or stat.S_IMODE(active_status.st_mode) != 0o700
                ):
                    raise DirectNotaryTransactionError(
                        "activated notary transaction identity is invalid"
                    )
                os.fsync(dist_descriptor)
                rebound_status = os.fstat(active_descriptor)
                if (
                    rebound_status.st_dev != active_status.st_dev
                    or rebound_status.st_ino != active_status.st_ino
                    or rebound_status.st_uid != active_status.st_uid
                    or rebound_status.st_mode != active_status.st_mode
                ):
                    raise DirectNotaryTransactionError(
                        "activated notary transaction changed before commit"
                    )
                os.close(initialization_lease_descriptor)
                initialization_lease_descriptor = -1
                os.close(initialization_coordinator_descriptor)
                initialization_coordinator_descriptor = -1
            finally:
                os.close(active_descriptor)
        finally:
            os.close(dist_descriptor)
        context["transaction"] = transaction_root
        inputs = rebase_candidate_inputs(
            inputs,
            old_root=initial_root,
            new_root=transaction_root,
        )
        inputs_root = transaction_root / "inputs"
        submitted_root = transaction_root / "submitted"
        precheck_root = transaction_root / "precheck"
        accepted_root = transaction_root / "accepted"
        final_root = transaction_root / "final"
        final_check_root = transaction_root / "final-check"
        context["manifest"] = inputs.manifest.pinned
        context["evidence"] = inputs.evidence.pinned
        context["attestation"] = inputs.attestation.pinned
        context["info"] = inputs.info.pinned
        state_store = STATE.StateStore(
            transaction_root,
            transaction_id,
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

        submitted = submitted_root / submission_name
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
        source_assertion(release_source)
        state_store.commit(
            "submission-ready",
            {
                "relativePath": f"submitted/{submission_name}",
                "sha256": submitted_seal.sha256,
                "size": submitted_seal.size,
            },
        )
        hook("submission-verified", context)

        state_store.commit(
            "submit-intent",
            {
                "submissionName": submission_name,
                "sha256": submitted_seal.sha256,
                "size": submitted_seal.size,
            },
        )
        preserve_transaction = True

        def submit() -> str:
            return run_checked(
                [
                    "xcrun",
                    "notarytool",
                    "submit",
                    str(submitted),
                    "--keychain-profile",
                    notary_profile,
                    "--no-wait",
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
        submission_identifier = parse_notary_submission(submit_output)
        state_store.commit(
            "submission-known",
            {
                "id": submission_identifier,
                "submissionName": submission_name,
                "sha256": submitted_seal.sha256,
                "size": submitted_seal.size,
            },
        )
        context["submission_id"] = Path(submission_identifier)
        hook("submission-known", context)
        wait_output = TRANSACTION.observe_sealed_phase(
            submitted_seal,
            lambda: run_checked(
                [
                    "xcrun",
                    "notarytool",
                    "wait",
                    submission_identifier,
                    "--keychain-profile",
                    notary_profile,
                    "--timeout",
                    "30m",
                    "--output-format",
                    "json",
                ],
                cwd=project_root,
                runner=runner,
                label="Apple notarization wait",
            ),
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        parse_notary_result(
            wait_output,
            expected_identifier=submission_identifier,
        )
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
        source_assertion(release_source)
        state_store.commit(
            "accepted",
            {
                "id": submission_identifier,
                "submissionName": submission_name,
                "sha256": submitted_seal.sha256,
                "size": submitted_seal.size,
            },
        )
        context["submission_id"] = Path(submission_identifier)
        accepted_receipt = transaction_root / "apple-accepted.json"
        write_private_json(
            accepted_receipt,
            {
                "schemaVersion": 2,
                "receiptType": "apple-accepted",
                "releaseChannel": release_channel,
                "archiveName": archive_name,
                "releaseSource": release_source.payload,
                "runtimeBuildEvidence": bound_runtime_build_evidence,
                "appleSubmission": {
                    "id": submission_identifier,
                    "status": "Accepted",
                    "sha256": submitted_seal.sha256,
                    "size": submitted_seal.size,
                },
                "candidateInputs": receipt_candidate_inputs(inputs),
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
        source_assertion(release_source)
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
        source_assertion(release_source)
        state_store.commit(
            "final-verified",
            {
                "archiveName": archive_name,
                "archiveRelativePath": str(
                    final_archive.relative_to(transaction_root)
                ),
                "checksumRelativePath": str(
                    final_checksum.relative_to(transaction_root)
                ),
                "sha256": final_seal.sha256,
                "size": final_seal.size,
                "checksumSHA256": checksum_seal.sha256,
                "checksumSize": checksum_seal.size,
            },
        )
        hook("final-verified", context)

        receipt = transaction_root / "notary-receipt.json"
        write_private_json(
            receipt,
            {
                "schemaVersion": 2,
                "receiptType": "direct-release",
                "releaseChannel": release_channel,
                "archiveName": archive_name,
                "releaseSource": release_source.payload,
                "runtimeBuildEvidence": bound_runtime_build_evidence,
                "candidateInputs": receipt_candidate_inputs(inputs),
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
        source_assertion(release_source)
        TRANSACTION.assert_checksum_matches_archive(
            final_seal,
            checksum_seal,
        )
        TRANSACTION.publish_or_adopt_sealed_file(
            checksum_seal,
            destination=checksum_destination,
            maximum_bytes=4 * 1024,
        )
        public_checksum_seal = TRANSACTION.seal_regular_file(
            checksum_destination,
            maximum_bytes=4 * 1024,
            allowed_link_counts=frozenset({2}),
        )
        def commit_sidecar() -> None:
            hook("sidecar-published", context)
            state_store.commit(
                "sidecar-committed",
                {
                    "name": checksum_destination.name,
                    "sha256": checksum_seal.sha256,
                    "size": checksum_seal.size,
                },
            )

        TRANSACTION.observe_sealed_phase(
            public_checksum_seal,
            commit_sidecar,
            maximum_bytes=4 * 1024,
            allowed_link_counts=frozenset({2}),
        )
        TRANSACTION.publish_or_adopt_sealed_file(
            final_seal,
            destination=archive_destination,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
        )
        public_archive_seal = TRANSACTION.seal_regular_file(
            archive_destination,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
            allowed_link_counts=frozenset({2}),
        )
        def commit_archive() -> None:
            hook("archive-published", context)
            state_store.commit(
                "zip-committed",
                {
                    "name": archive_destination.name,
                    "sha256": final_seal.sha256,
                    "size": final_seal.size,
                },
            )
            hook("zip-committed", context)

        TRANSACTION.observe_sealed_phase(
            public_archive_seal,
            commit_archive,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
            allowed_link_counts=frozenset({2}),
        )

        def complete_publication() -> None:
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
                    str(archive_destination),
                    "--expected-info-plist",
                    str(inputs.info.pinned),
                ],
                cwd=project_root,
                runner=runner,
                label="published notarized archive verification",
            )
            TRANSACTION.assert_checksum_matches_archive(
                public_archive_seal,
                public_checksum_seal,
            )
            source_assertion(release_source)
            assert_candidate_inputs_unchanged(inputs)
            state_store.commit(
                "publication-complete",
                {
                    "archiveName": archive_name,
                    "sha256": final_seal.sha256,
                    "receipt": receipt_destination.name,
                },
            )
            hook("published", context)

        observe_public_release_pair(
            public_archive_seal,
            public_checksum_seal,
            complete_publication,
        )
        TRANSACTION.assert_sealed(
            public_archive_seal,
            maximum_bytes=MAXIMUM_ARCHIVE_BYTES,
            allowed_link_counts=frozenset({2}),
        )
        TRANSACTION.assert_sealed(
            public_checksum_seal,
            maximum_bytes=4 * 1024,
            allowed_link_counts=frozenset({2}),
        )
        transaction_complete = True
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
        SOURCE.ReleaseSourceReceiptError,
        STATE.NotaryTransactionStateError,
    ) as error:
        raise DirectNotaryTransactionError(
            "Direct notarization transaction failed"
        ) from error
    finally:
        try:
            if not preserve_transaction or transaction_complete:
                retirement = retire_exact_transaction(
                    transaction_root,
                    descriptor=transaction_descriptor,
                    expected_device=transaction_status.st_dev,
                    expected_inode=transaction_status.st_ino,
                )
                if transaction_complete and (
                    not retirement.verified
                    or not retirement.durable
                ):
                    raise DirectNotaryTransactionError(
                        "completed notary transaction could not be safely retired"
                    )
        finally:
            try:
                os.close(transaction_descriptor)
            finally:
                if lock_descriptor >= 0:
                    os.close(lock_descriptor)
                for initialization_descriptor in (
                    initialization_lease_descriptor,
                    initialization_coordinator_descriptor,
                ):
                    if initialization_descriptor >= 0:
                        try:
                            os.close(initialization_descriptor)
                        except OSError:
                            pass


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
