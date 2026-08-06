#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path


class NotaryTransactionInspectionError(RuntimeError):
    pass


_INITIAL_NAME = re.compile(
    r"^\.neantik-notary-init\."
    r"(?P<id>[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12})$"
)
_ACTIVE_NAME = re.compile(
    r"^\.neantik-notary\."
    r"(?P<id>[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12})$"
)
_RETIRED_NAME = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_RESUME_NAME = re.compile(r"^resume-[0-9a-f]{32}$")
_STATE_TEMPORARY_NAME = re.compile(
    r"^\.[0-9]{2}-[a-z-]+\.[0-9a-f]{64}\.json"
    r"\.tmp-[0-9a-f]{32}$"
)
_ROOT_TEMPORARY_NAME = re.compile(
    r"^\.(?:init-marker|apple-accepted|notary-receipt|"
    r"notary-reconciliation)\.json"
    r"\.tmp-[0-9a-f]{32}$"
)
_STAGES: tuple[tuple[str, str], ...] = (
    ("00", "transaction-created"),
    ("10", "submission-ready"),
    ("11", "submit-intent"),
    ("20", "submission-known"),
    ("30", "accepted"),
    ("40", "final-verified"),
    ("50", "sidecar-committed"),
    ("60", "zip-committed"),
    ("70", "publication-complete"),
)
_ALLOWED_ROOT_ENTRIES = frozenset(
    {
        # Finder may add this inert metadata file when an operator opens the
        # private release directory. It is never read as transaction input.
        ".DS_Store",
        ".init-lease",
        ".init-marker.json",
        "accepted",
        "apple-accepted.json",
        "final",
        "final-check",
        "inputs",
        "notary-receipt.json",
        "notary-reconciliation.json",
        "precheck",
        "state",
        "submitted",
    }
)
_PRIVATE_DIRECTORIES = frozenset(
    {
        "accepted",
        "final",
        "final-check",
        "inputs",
        "precheck",
        "submitted",
    }
)
_REQUIRED_TRANSACTION_DIRECTORIES = _PRIVATE_DIRECTORIES | {"state"}
_MAXIMUM_DIST_ENTRIES = 1_024
_MAXIMUM_RETIRED_ENTRIES = 10_000
_MAXIMUM_ROOT_ENTRIES = 1_056
_MAXIMUM_STATE_ENTRIES = len(_STAGES) * 2
_MAXIMUM_MARKER_BYTES = 16 * 1024
_MAXIMUM_STATE_BYTES = 4 * 1024 * 1024
_MAXIMUM_RECEIPT_BYTES = 4 * 1024 * 1024
_MAXIMUM_EMITTED_RECORDS = 64
_MAXIMUM_RESUME_DIRECTORIES = 1_024
_MAXIMUM_LOCK_ENTRIES = 10_000
_MAXIMUM_ARCHIVE_BYTES = 16 * 1024 * 1024 * 1024
_MAXIMUM_CHECKSUM_BYTES = 4 * 1024
_MAXIMUM_JSON_DEPTH = 64
_MAXIMUM_JSON_NODES = 100_000
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_ARCHIVE = re.compile(
    r"^NeAntik-[0-9]+\.[0-9]+\.[0-9]+-arm64-notarized\.zip$"
)


@dataclass(frozen=True)
class InspectionRecord:
    category: str
    status: str
    stage: str | None
    externalEffect: str
    structurallySafe: bool
    releaseBlocking: bool
    operatorAction: bool
    liveLease: bool | None
    reasonCode: str


def _canonical_json_bytes(payload: object) -> bytes:
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


def _canonical_uuid(value: object) -> str:
    if not isinstance(value, str):
        raise NotaryTransactionInspectionError("invalid-uuid")
    try:
        normalized = str(uuid.UUID(value))
    except (ValueError, AttributeError) as error:
        raise NotaryTransactionInspectionError(
            "invalid-uuid"
        ) from error
    if normalized != value:
        raise NotaryTransactionInspectionError("invalid-uuid")
    return value


def _directory_flags() -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def _file_flags() -> int:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def _validate_directory(
    descriptor: int,
    *,
    expected_device: int | None,
    private: bool,
) -> os.stat_result:
    status = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_uid != os.geteuid()
        or (private and stat.S_IMODE(status.st_mode) != 0o700)
        or (not private and status.st_mode & 0o022)
        or (
            expected_device is not None
            and status.st_dev != expected_device
        )
    ):
        raise NotaryTransactionInspectionError("unsafe-directory")
    return status


def _open_directory_at(
    parent: int,
    name: str,
    *,
    expected_device: int,
    private: bool = True,
) -> tuple[int, os.stat_result]:
    try:
        descriptor = os.open(
            name,
            _directory_flags(),
            dir_fd=parent,
        )
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "directory-unavailable"
        ) from error
    try:
        status = _validate_directory(
            descriptor,
            expected_device=expected_device,
            private=private,
        )
        return descriptor, status
    except Exception:
        os.close(descriptor)
        raise


def _list_directory(descriptor: int, *, maximum: int) -> tuple[str, ...]:
    try:
        names: list[str] = []
        with os.scandir(descriptor) as entries:
            for entry in entries:
                if len(names) >= maximum:
                    raise NotaryTransactionInspectionError(
                        "directory-entry-limit"
                    )
                name = entry.name
                if (
                    not isinstance(name, str)
                    or not name
                    or "/" in name
                    or "\0" in name
                    or any(
                        0xD800 <= ord(character) <= 0xDFFF
                        for character in name
                    )
                ):
                    raise NotaryTransactionInspectionError(
                        "invalid-entry-name"
                    )
                names.append(name)
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "directory-unreadable"
        ) from error
    return tuple(sorted(names))


def _read_regular_file_at(
    parent: int,
    name: str,
    *,
    expected_device: int,
    expected_mode: int,
    maximum_bytes: int,
) -> bytes:
    try:
        entry_before = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "file-unavailable"
        ) from error
    try:
        descriptor = os.open(
            name,
            _file_flags(),
            dir_fd=parent,
        )
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "file-unavailable"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_dev != expected_device
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != expected_mode
            or before.st_size <= 0
            or before.st_size > maximum_bytes
            or entry_before.st_dev != before.st_dev
            or entry_before.st_ino != before.st_ino
            or entry_before.st_mode != before.st_mode
            or entry_before.st_uid != before.st_uid
            or entry_before.st_nlink != before.st_nlink
            or entry_before.st_size != before.st_size
            or entry_before.st_mtime_ns != before.st_mtime_ns
            or entry_before.st_ctime_ns != before.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError("unsafe-file")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise NotaryTransactionInspectionError(
                    "file-size-limit"
                )
            chunks.append(chunk)
        after = os.fstat(descriptor)
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "file-unreadable"
        ) from error
    finally:
        os.close(descriptor)
    try:
        entry_after = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "file-changed"
        ) from error
    if (
        before.st_dev != after.st_dev
        or before.st_ino != after.st_ino
        or before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
        or total != after.st_size
        or entry_after.st_dev != after.st_dev
        or entry_after.st_ino != after.st_ino
        or entry_after.st_mode != after.st_mode
        or entry_after.st_uid != after.st_uid
        or entry_after.st_nlink != after.st_nlink
        or entry_after.st_size != after.st_size
        or entry_after.st_mtime_ns != after.st_mtime_ns
        or entry_after.st_ctime_ns != after.st_ctime_ns
    ):
        raise NotaryTransactionInspectionError(
            "file-changed"
        )
    return b"".join(chunks)


def _validate_regular_file_metadata_at(
    parent: int,
    name: str,
    *,
    expected_device: int,
    expected_mode: int,
    maximum_bytes: int,
) -> None:
    descriptor = -1
    try:
        entry_before = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        descriptor = os.open(name, _file_flags(), dir_fd=parent)
        status = os.fstat(descriptor)
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_uid != os.geteuid()
            or status.st_dev != expected_device
            or status.st_nlink != 1
            or stat.S_IMODE(status.st_mode) != expected_mode
            or status.st_size <= 0
            or status.st_size > maximum_bytes
            or entry_before.st_dev != status.st_dev
            or entry_before.st_ino != status.st_ino
            or entry_before.st_mode != status.st_mode
            or entry_before.st_uid != status.st_uid
            or entry_before.st_nlink != status.st_nlink
            or entry_before.st_size != status.st_size
            or entry_before.st_mtime_ns != status.st_mtime_ns
            or entry_before.st_ctime_ns != status.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError("unsafe-file")
        entry_after = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        after = os.fstat(descriptor)
        if (
            entry_after.st_dev != after.st_dev
            or entry_after.st_ino != after.st_ino
            or entry_after.st_mode != after.st_mode
            or entry_after.st_uid != after.st_uid
            or entry_after.st_nlink != after.st_nlink
            or entry_after.st_size != after.st_size
            or entry_after.st_mtime_ns != after.st_mtime_ns
            or entry_after.st_ctime_ns != after.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError("file-changed")
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "file-unavailable"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _validate_temporary_file_at(
    parent: int,
    name: str,
    *,
    expected_device: int,
    maximum_bytes: int,
) -> None:
    descriptor = -1
    try:
        entry = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        descriptor = os.open(name, _file_flags(), dir_fd=parent)
        status = os.fstat(descriptor)
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_uid != os.geteuid()
            or status.st_dev != expected_device
            or status.st_nlink != 1
            or stat.S_IMODE(status.st_mode) not in {0o400, 0o600}
            or status.st_size < 0
            or status.st_size > maximum_bytes
            or entry.st_dev != status.st_dev
            or entry.st_ino != status.st_ino
            or entry.st_mode != status.st_mode
            or entry.st_uid != status.st_uid
            or entry.st_nlink != status.st_nlink
            or entry.st_size != status.st_size
            or entry.st_mtime_ns != status.st_mtime_ns
            or entry.st_ctime_ns != status.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError(
                "unsafe-temporary-file"
            )
        after = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        if (
            after.st_dev != status.st_dev
            or after.st_ino != status.st_ino
            or after.st_mode != status.st_mode
            or after.st_size != status.st_size
            or after.st_mtime_ns != status.st_mtime_ns
            or after.st_ctime_ns != status.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError(
                "temporary-file-changed"
            )
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "temporary-file-unavailable"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _seal_regular_file_at(
    parent: int,
    name: str,
    *,
    expected_device: int,
    expected_mode: int,
    maximum_bytes: int,
    allowed_link_counts: frozenset[int] = frozenset({1}),
) -> tuple[str, int]:
    try:
        entry_before = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        descriptor = os.open(name, _file_flags(), dir_fd=parent)
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "sealed-file-unavailable"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_dev != expected_device
            or before.st_nlink not in allowed_link_counts
            or stat.S_IMODE(before.st_mode) != expected_mode
            or before.st_size <= 0
            or before.st_size > maximum_bytes
            or entry_before.st_dev != before.st_dev
            or entry_before.st_ino != before.st_ino
            or entry_before.st_mode != before.st_mode
            or entry_before.st_uid != before.st_uid
            or entry_before.st_nlink != before.st_nlink
            or entry_before.st_size != before.st_size
            or entry_before.st_mtime_ns != before.st_mtime_ns
            or entry_before.st_ctime_ns != before.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError(
                "unsafe-sealed-file"
            )
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise NotaryTransactionInspectionError(
                    "sealed-file-size-limit"
                )
            digest.update(chunk)
        after = os.fstat(descriptor)
        entry_after = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "sealed-file-unreadable"
        ) from error
    finally:
        os.close(descriptor)
    if (
        before.st_dev != after.st_dev
        or before.st_ino != after.st_ino
        or before.st_mode != after.st_mode
        or before.st_uid != after.st_uid
        or before.st_nlink != after.st_nlink
        or before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
        or total != after.st_size
        or entry_after.st_dev != after.st_dev
        or entry_after.st_ino != after.st_ino
        or entry_after.st_mode != after.st_mode
        or entry_after.st_uid != after.st_uid
        or entry_after.st_nlink != after.st_nlink
        or entry_after.st_size != after.st_size
        or entry_after.st_mtime_ns != after.st_mtime_ns
        or entry_after.st_ctime_ns != after.st_ctime_ns
    ):
        raise NotaryTransactionInspectionError(
            "sealed-file-changed"
        )
    return digest.hexdigest(), total


def _require_keys(
    value: object,
    expected: frozenset[str],
    *,
    code: str,
) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != expected:
        raise NotaryTransactionInspectionError(code)
    return value


def _require_sha(value: object, *, code: str) -> str:
    if not isinstance(value, str) or _SHA256.fullmatch(value) is None:
        raise NotaryTransactionInspectionError(code)
    return value


def _require_size(
    value: object,
    *,
    maximum: int,
    code: str,
) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value <= 0
        or value > maximum
    ):
        raise NotaryTransactionInspectionError(code)
    return value


def _validate_state_data(
    receipts: tuple[tuple[str, dict[str, object]], ...],
    *,
    transaction_id: str,
) -> dict[str, object]:
    context: dict[str, object] = {}
    for stage, raw_data in receipts:
        if stage == "transaction-created":
            data = _require_keys(
                raw_data,
                frozenset(
                    {
                        "archiveName",
                        "submissionName",
                        "releaseChannel",
                        "candidateInputs",
                        "releaseSource",
                        "runtimeBuildEvidence",
                    }
                ),
                code="invalid-transaction-created-data",
            )
            archive = data["archiveName"]
            if (
                not isinstance(archive, str)
                or _ARCHIVE.fullmatch(archive) is None
                or data["submissionName"]
                != f"{transaction_id}-{archive}"
                or data["releaseChannel"]
                not in {"public-alpha", "production"}
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-transaction-created-data"
                )
            inputs = data["candidateInputs"]
            legacy_input_keys = frozenset(
                {"infoPlist", "manifest", "evidence", "attestation"}
            )
            source_bound_input_keys = legacy_input_keys | {
                "sourceBinding"
            }
            if (
                not isinstance(inputs, dict)
                or set(inputs)
                not in {legacy_input_keys, source_bound_input_keys}
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-candidate-inputs"
                )
            for value in inputs.values():
                _require_sha(value, code="invalid-candidate-inputs")
            if (
                not isinstance(data["releaseSource"], dict)
                or not isinstance(data["runtimeBuildEvidence"], dict)
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-transaction-created-data"
                )
            context.update(
                archive=archive,
                submission=data["submissionName"],
            )
            continue
        if stage == "submission-ready":
            data = _require_keys(
                raw_data,
                frozenset({"relativePath", "sha256", "size"}),
                code="invalid-submission-ready-data",
            )
            if data["relativePath"] != f"submitted/{context['submission']}":
                raise NotaryTransactionInspectionError(
                    "invalid-submission-ready-data"
                )
            context["submittedSHA256"] = _require_sha(
                data["sha256"],
                code="invalid-submission-ready-data",
            )
            context["submittedSize"] = _require_size(
                data["size"],
                maximum=_MAXIMUM_ARCHIVE_BYTES,
                code="invalid-submission-ready-data",
            )
            continue
        if stage == "submit-intent":
            data = _require_keys(
                raw_data,
                frozenset({"submissionName", "sha256", "size"}),
                code="invalid-submit-intent-data",
            )
            if (
                data["submissionName"] != context["submission"]
                or data["sha256"] != context["submittedSHA256"]
                or data["size"] != context["submittedSize"]
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-submit-intent-data"
                )
            continue
        if stage in {"submission-known", "accepted"}:
            data = _require_keys(
                raw_data,
                frozenset({"id", "submissionName", "sha256", "size"}),
                code=f"invalid-{stage}-data",
            )
            submission_id = _canonical_uuid(data["id"])
            known_id = context.get("appleSubmissionId")
            if (
                data["submissionName"] != context["submission"]
                or data["sha256"] != context["submittedSHA256"]
                or data["size"] != context["submittedSize"]
                or (known_id is not None and submission_id != known_id)
            ):
                raise NotaryTransactionInspectionError(
                    f"invalid-{stage}-data"
                )
            context["appleSubmissionId"] = submission_id
            continue
        if stage == "final-verified":
            data = _require_keys(
                raw_data,
                frozenset(
                    {
                        "archiveName",
                        "archiveRelativePath",
                        "checksumRelativePath",
                        "sha256",
                        "size",
                        "checksumSHA256",
                        "checksumSize",
                    }
                ),
                code="invalid-final-verified-data",
            )
            archive_relative = data["archiveRelativePath"]
            checksum_relative = data["checksumRelativePath"]
            direct_archive = f"final/{context['archive']}"
            direct_checksum = f"{direct_archive}.sha256"
            recovery_match = (
                re.fullmatch(
                    rf"(resume-[0-9a-f]{{32}})/final/"
                    rf"{re.escape(str(context['archive']))}",
                    archive_relative,
                )
                if isinstance(archive_relative, str)
                else None
            )
            recovery_checksum = (
                f"{recovery_match.group(1)}/final/"
                f"{context['archive']}.sha256"
                if recovery_match is not None
                else None
            )
            if (
                data["archiveName"] != context["archive"]
                or (
                    (archive_relative, checksum_relative)
                    != (direct_archive, direct_checksum)
                    and (
                        recovery_match is None
                        or checksum_relative != recovery_checksum
                    )
                )
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-final-verified-data"
                )
            context["archiveRelativePath"] = archive_relative
            context["checksumRelativePath"] = checksum_relative
            context["finalSHA256"] = _require_sha(
                data["sha256"],
                code="invalid-final-verified-data",
            )
            context["finalSize"] = _require_size(
                data["size"],
                maximum=_MAXIMUM_ARCHIVE_BYTES,
                code="invalid-final-verified-data",
            )
            context["checksumSHA256"] = _require_sha(
                data["checksumSHA256"],
                code="invalid-final-verified-data",
            )
            context["checksumSize"] = _require_size(
                data["checksumSize"],
                maximum=_MAXIMUM_CHECKSUM_BYTES,
                code="invalid-final-verified-data",
            )
            expected_sidecar = (
                f"{context['finalSHA256']}  {context['archive']}\n"
            ).encode("utf-8")
            if (
                context["checksumSize"] != len(expected_sidecar)
                or context["checksumSHA256"]
                != hashlib.sha256(expected_sidecar).hexdigest()
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-final-verified-data"
                )
            continue
        if stage in {"sidecar-committed", "zip-committed"}:
            data = _require_keys(
                raw_data,
                frozenset({"name", "sha256", "size"}),
                code=f"invalid-{stage}-data",
            )
            expected_name = str(context["archive"]) + (
                ".sha256" if stage == "sidecar-committed" else ""
            )
            if data["name"] != expected_name:
                raise NotaryTransactionInspectionError(
                    f"invalid-{stage}-data"
                )
            _require_sha(data["sha256"], code=f"invalid-{stage}-data")
            _require_size(
                data["size"],
                maximum=(
                    _MAXIMUM_CHECKSUM_BYTES
                    if stage == "sidecar-committed"
                    else _MAXIMUM_ARCHIVE_BYTES
                ),
                code=f"invalid-{stage}-data",
            )
            expected_sha = context[
                "checksumSHA256"
                if stage == "sidecar-committed"
                else "finalSHA256"
            ]
            expected_size = context[
                "checksumSize"
                if stage == "sidecar-committed"
                else "finalSize"
            ]
            if (
                data["sha256"] != expected_sha
                or data["size"] != expected_size
            ):
                raise NotaryTransactionInspectionError(
                    f"invalid-{stage}-data"
                )
            continue
        if stage == "publication-complete":
            allowed = (
                frozenset(
                    {"archiveName", "sha256", "receipt"}
                ),
                frozenset(
                    {
                        "archiveName",
                        "archiveRelativePath",
                        "checksumRelativePath",
                        "sha256",
                        "receipt",
                    }
                ),
            )
            if not isinstance(raw_data, dict) or frozenset(raw_data) not in allowed:
                raise NotaryTransactionInspectionError(
                    "invalid-publication-complete-data"
                )
            if (
                raw_data["archiveName"] != context["archive"]
                or raw_data["sha256"] != context["finalSHA256"]
                or not isinstance(raw_data["receipt"], str)
                or raw_data["receipt"]
                != (
                    f"{context['archive']}."
                    f"{context['appleSubmissionId']}.receipt.json"
                )
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-publication-complete-data"
                )
            if "archiveRelativePath" in raw_data and (
                raw_data["archiveRelativePath"]
                != context["archiveRelativePath"]
                or raw_data["checksumRelativePath"]
                != context["checksumRelativePath"]
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-publication-complete-data"
                )
    return context


def _decode_canonical_json(raw: bytes) -> dict[str, object]:
    def reject_duplicates(
        pairs: list[tuple[str, object]],
    ) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise NotaryTransactionInspectionError(
                    "duplicate-json-key"
                )
            result[key] = value
        return result

    try:
        payload = json.loads(
            raw,
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                NotaryTransactionInspectionError(
                    "non-finite-json-value"
                )
            ),
        )
    except (
        json.JSONDecodeError,
        UnicodeDecodeError,
        ValueError,
        RecursionError,
    ) as error:
        raise NotaryTransactionInspectionError(
            "invalid-json"
        ) from error
    nodes = 0
    stack: list[tuple[object, int]] = [(payload, 0)]
    while stack:
        value, depth = stack.pop()
        nodes += 1
        if nodes > _MAXIMUM_JSON_NODES or depth > _MAXIMUM_JSON_DEPTH:
            raise NotaryTransactionInspectionError(
                "invalid-json-complexity"
            )
        if isinstance(value, dict):
            stack.extend(
                (child, depth + 1) for child in value.values()
            )
        elif isinstance(value, list):
            stack.extend((child, depth + 1) for child in value)
    if (
        not isinstance(payload, dict)
        or _canonical_json_bytes(payload) != raw
    ):
        raise NotaryTransactionInspectionError(
            "non-canonical-json"
        )
    return payload


def _read_marker(
    root: int,
    *,
    expected_device: int,
) -> dict[str, object]:
    payload = _decode_canonical_json(
        _read_regular_file_at(
            root,
            ".init-marker.json",
            expected_device=expected_device,
            expected_mode=0o400,
            maximum_bytes=_MAXIMUM_MARKER_BYTES,
        )
    )
    if set(payload) != {
        "activeTarget",
        "createdAtUnixNs",
        "directoryName",
        "externalEffectsAllowed",
        "markerType",
        "schemaVersion",
        "transactionId",
    }:
        raise NotaryTransactionInspectionError(
            "invalid-marker-schema"
        )
    transaction_id = _canonical_uuid(payload.get("transactionId"))
    created_at = payload.get("createdAtUnixNs")
    if (
        payload.get("schemaVersion") != 1
        or payload.get("markerType")
        != "neantik-notary-initialization"
        or payload.get("externalEffectsAllowed") is not False
        or not isinstance(created_at, int)
        or isinstance(created_at, bool)
        or created_at <= 0
        or payload.get("directoryName")
        != f".neantik-notary-init.{transaction_id}"
        or payload.get("activeTarget")
        != f".neantik-notary.{transaction_id}"
    ):
        raise NotaryTransactionInspectionError(
            "invalid-marker-schema"
        )
    return payload


def _read_reconciliation_marker(
    root: int,
    *,
    expected_device: int,
    transaction_id: str,
    state_context: dict[str, object],
) -> dict[str, object]:
    payload = _decode_canonical_json(
        _read_regular_file_at(
            root,
            "notary-reconciliation.json",
            expected_device=expected_device,
            expected_mode=0o400,
            maximum_bytes=_MAXIMUM_MARKER_BYTES,
        )
    )
    if set(payload) != {
        "archiveName",
        "checkedAtUnixNs",
        "historySHA256",
        "markerType",
        "result",
        "schemaVersion",
        "submissionNameSHA256",
        "transactionId",
    }:
        raise NotaryTransactionInspectionError(
            "invalid-reconciliation-schema"
        )
    checked_at = payload.get("checkedAtUnixNs")
    submission_name = state_context.get("submission")
    if (
        payload.get("schemaVersion") != 1
        or payload.get("markerType")
        != "neantik-notary-reconciliation"
        or payload.get("result") != "submission-absent"
        or payload.get("transactionId") != transaction_id
        or payload.get("archiveName") != state_context.get("archive")
        or not isinstance(checked_at, int)
        or isinstance(checked_at, bool)
        or checked_at <= 0
        or not isinstance(submission_name, str)
        or payload.get("submissionNameSHA256")
        != hashlib.sha256(submission_name.encode("utf-8")).hexdigest()
    ):
        raise NotaryTransactionInspectionError(
            "invalid-reconciliation-schema"
        )
    _require_sha(
        payload.get("historySHA256"),
        code="invalid-reconciliation-schema",
    )
    return payload


def _exclusive_lock_is_live(
    parent: int,
    name: str,
    *,
    expected_device: int,
) -> bool:
    try:
        descriptor = os.open(
            name,
            _file_flags(),
            dir_fd=parent,
        )
    except OSError as error:
        raise NotaryTransactionInspectionError(
            "lease-unavailable"
        ) from error
    acquired = False
    try:
        status = os.fstat(descriptor)
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_uid != os.geteuid()
            or status.st_dev != expected_device
            or status.st_nlink != 1
            or stat.S_IMODE(status.st_mode) != 0o600
            or status.st_size != 0
        ):
            raise NotaryTransactionInspectionError("unsafe-lease")
        try:
            fcntl.flock(
                descriptor,
                fcntl.LOCK_SH | fcntl.LOCK_NB,
            )
            acquired = True
        except BlockingIOError:
            return True
        return False
    finally:
        if acquired:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _lease_is_live(
    root: int,
    *,
    expected_device: int,
) -> bool:
    return _exclusive_lock_is_live(
        root,
        ".init-lease",
        expected_device=expected_device,
    )


def _read_state_chain(
    root: int,
    *,
    expected_device: int,
) -> tuple[
    str | None,
    str | None,
    bool,
    dict[str, object],
]:
    names = _list_directory(root, maximum=_MAXIMUM_ROOT_ENTRIES)
    if "state" not in names:
        return None, None, False, {}
    state_descriptor, state_status = _open_directory_at(
        root,
        "state",
        expected_device=expected_device,
    )
    try:
        state_names = _list_directory(
            state_descriptor,
            maximum=_MAXIMUM_STATE_ENTRIES,
        )
        temporary_names = tuple(
            name for name in state_names if name.startswith(".")
        )
        if any(
            _STATE_TEMPORARY_NAME.fullmatch(name) is None
            for name in temporary_names
        ):
            raise NotaryTransactionInspectionError(
                "unknown-state-temporary"
            )
        for name in temporary_names:
            _validate_temporary_file_at(
                state_descriptor,
                name,
                expected_device=expected_device,
                maximum_bytes=_MAXIMUM_STATE_BYTES,
            )
        final_names = tuple(
            name for name in state_names if not name.startswith(".")
        )
        if len(final_names) > len(_STAGES):
            raise NotaryTransactionInspectionError(
                "invalid-state-sequence"
            )
        previous: str | None = None
        transaction_id: str | None = None
        latest: str | None = None
        receipts: list[tuple[str, dict[str, object]]] = []
        for (prefix, expected_stage), name in zip(
            _STAGES,
            final_names,
            strict=False,
        ):
            match = re.fullmatch(
                rf"{prefix}-{re.escape(expected_stage)}"
                r"\.([0-9a-f]{64})\.json",
                name,
            )
            if match is None:
                raise NotaryTransactionInspectionError(
                    "invalid-state-sequence"
                )
            raw = _read_regular_file_at(
                state_descriptor,
                name,
                expected_device=expected_device,
                expected_mode=0o400,
                maximum_bytes=_MAXIMUM_STATE_BYTES,
            )
            payload = _decode_canonical_json(raw)
            digest = hashlib.sha256(raw).hexdigest()
            if (
                set(payload)
                != {
                    "data",
                    "previousReceiptSHA256",
                    "schemaVersion",
                    "state",
                    "transactionId",
                }
                or payload.get("schemaVersion") != 1
                or not isinstance(payload.get("data"), dict)
                or payload.get("state") != expected_stage
                or payload.get("previousReceiptSHA256") != previous
                or digest != match.group(1)
            ):
                raise NotaryTransactionInspectionError(
                    "invalid-state-chain"
                )
            observed_id = _canonical_uuid(
                payload.get("transactionId")
            )
            if transaction_id is None:
                transaction_id = observed_id
            elif transaction_id != observed_id:
                raise NotaryTransactionInspectionError(
                    "invalid-state-chain"
                )
            previous = digest
            latest = expected_stage
            data = payload["data"]
            assert isinstance(data, dict)
            receipts.append((expected_stage, data))
        context: dict[str, object] = {}
        if transaction_id is not None:
            context = _validate_state_data(
                tuple(receipts),
                transaction_id=transaction_id,
            )
        state_names_after = _list_directory(
            state_descriptor,
            maximum=_MAXIMUM_STATE_ENTRIES,
        )
        state_after = os.fstat(state_descriptor)
        if (
            state_names != state_names_after
            or state_status.st_dev != state_after.st_dev
            or state_status.st_ino != state_after.st_ino
            or state_status.st_mtime_ns != state_after.st_mtime_ns
            or state_status.st_ctime_ns != state_after.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError(
                "state-directory-changed"
            )
        return (
            latest,
            transaction_id,
            bool(temporary_names),
            context,
        )
    finally:
        os.close(state_descriptor)


def _validate_private_children(
    root: int,
    names: tuple[str, ...],
    *,
    expected_device: int,
) -> None:
    for name in sorted(_PRIVATE_DIRECTORIES.intersection(names)):
        descriptor, _status = _open_directory_at(
            root,
            name,
            expected_device=expected_device,
        )
        os.close(descriptor)


def _validate_resume_directories(
    root: int,
    names: tuple[str, ...],
    *,
    expected_device: int,
) -> None:
    resume_names = tuple(
        name for name in names if _RESUME_NAME.fullmatch(name)
    )
    if len(resume_names) > _MAXIMUM_RESUME_DIRECTORIES:
        raise NotaryTransactionInspectionError(
            "resume-directory-limit"
        )
    for name in resume_names:
        descriptor, before = _open_directory_at(
            root,
            name,
            expected_device=expected_device,
        )
        try:
            children = _list_directory(descriptor, maximum=3)
            if tuple(children) not in {
                (),
                ("accepted",),
                ("accepted", "final"),
                ("accepted", "final", "final-check"),
            }:
                raise NotaryTransactionInspectionError(
                    "invalid-resume-directory"
                )
            _validate_private_children(
                descriptor,
                children,
                expected_device=expected_device,
            )
            after = os.fstat(descriptor)
            if (
                before.st_dev != after.st_dev
                or before.st_ino != after.st_ino
                or before.st_mtime_ns != after.st_mtime_ns
                or before.st_ctime_ns != after.st_ctime_ns
                or children
                != _list_directory(descriptor, maximum=3)
            ):
                raise NotaryTransactionInspectionError(
                    "resume-directory-changed"
                )
        finally:
            os.close(descriptor)


def _validate_active_artifacts(
    root: int,
    *,
    stage: str,
    context: dict[str, object],
    expected_device: int,
) -> None:
    stage_names = tuple(name for _prefix, name in _STAGES)
    stage_index = stage_names.index(stage)
    if stage_index < stage_names.index("submission-known"):
        return
    submission_name = context.get("submission")
    submitted_sha = context.get("submittedSHA256")
    submitted_size = context.get("submittedSize")
    if (
        not isinstance(submission_name, str)
        or not isinstance(submitted_sha, str)
        or not isinstance(submitted_size, int)
    ):
        raise NotaryTransactionInspectionError(
            "submitted-artifact-state-missing"
        )
    submitted, submitted_before = _open_directory_at(
        root,
        "submitted",
        expected_device=expected_device,
    )
    try:
        if _list_directory(submitted, maximum=1) != (submission_name,):
            raise NotaryTransactionInspectionError(
                "submitted-artifact-inventory-invalid"
            )
        observed_sha, observed_size = _seal_regular_file_at(
            submitted,
            submission_name,
            expected_device=expected_device,
            expected_mode=0o400,
            maximum_bytes=_MAXIMUM_ARCHIVE_BYTES,
        )
        submitted_after = os.fstat(submitted)
        if (
            observed_sha != submitted_sha
            or observed_size != submitted_size
            or submitted_before.st_mtime_ns
            != submitted_after.st_mtime_ns
            or submitted_before.st_ctime_ns
            != submitted_after.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError(
                "submitted-artifact-mismatch"
            )
    finally:
        os.close(submitted)
    if stage_index < stage_names.index("final-verified"):
        return
    archive_relative = context.get("archiveRelativePath")
    checksum_relative = context.get("checksumRelativePath")
    if (
        not isinstance(archive_relative, str)
        or not isinstance(checksum_relative, str)
    ):
        raise NotaryTransactionInspectionError(
            "final-artifact-state-missing"
        )
    archive_parts = archive_relative.split("/")
    checksum_parts = checksum_relative.split("/")
    if len(archive_parts) == 2:
        parent = root
        parent_name = "final"
        parent_descriptor = -1
    elif len(archive_parts) == 3:
        resume_descriptor, _resume_status = _open_directory_at(
            root,
            archive_parts[0],
            expected_device=expected_device,
        )
        parent = resume_descriptor
        parent_name = "final"
        parent_descriptor = resume_descriptor
    else:
        raise NotaryTransactionInspectionError(
            "final-artifact-path-invalid"
        )
    final_descriptor = -1
    try:
        final_descriptor, final_before = _open_directory_at(
            parent,
            parent_name,
            expected_device=expected_device,
        )
        archive_name = archive_parts[-1]
        checksum_name = checksum_parts[-1]
        inventory = _list_directory(final_descriptor, maximum=4)
        base_names = {archive_name, checksum_name}
        hidden_by_base: dict[str, str] = {}
        for entry_name in inventory:
            if entry_name in base_names:
                continue
            matched_base = next(
                (
                    base
                    for base in base_names
                    if re.fullmatch(
                        rf"\.{re.escape(base)}"
                        r"\.neantik-publish-[0-9a-f]{32}",
                        entry_name,
                    )
                ),
                None,
            )
            if matched_base is None or matched_base in hidden_by_base:
                raise NotaryTransactionInspectionError(
                    "final-artifact-inventory-invalid"
                )
            hidden_by_base[matched_base] = entry_name
        if not base_names.issubset(inventory):
            raise NotaryTransactionInspectionError(
                "final-artifact-inventory-invalid"
            )
        final_sha, final_size = _seal_regular_file_at(
            final_descriptor,
            archive_name,
            expected_device=expected_device,
            expected_mode=0o400,
            maximum_bytes=_MAXIMUM_ARCHIVE_BYTES,
            allowed_link_counts=frozenset({1, 2}),
        )
        checksum_sha, checksum_size = _seal_regular_file_at(
            final_descriptor,
            checksum_name,
            expected_device=expected_device,
            expected_mode=0o400,
            maximum_bytes=_MAXIMUM_CHECKSUM_BYTES,
            allowed_link_counts=frozenset({1, 2}),
        )
        for base_name, hidden_name in hidden_by_base.items():
            base_status = os.stat(
                base_name,
                dir_fd=final_descriptor,
                follow_symlinks=False,
            )
            hidden_status = os.stat(
                hidden_name,
                dir_fd=final_descriptor,
                follow_symlinks=False,
            )
            hidden_sha, hidden_size = _seal_regular_file_at(
                final_descriptor,
                hidden_name,
                expected_device=expected_device,
                expected_mode=0o400,
                maximum_bytes=(
                    _MAXIMUM_CHECKSUM_BYTES
                    if base_name == checksum_name
                    else _MAXIMUM_ARCHIVE_BYTES
                ),
                allowed_link_counts=frozenset({2}),
            )
            expected_hidden_sha = (
                context.get("checksumSHA256")
                if base_name == checksum_name
                else context.get("finalSHA256")
            )
            expected_hidden_size = (
                context.get("checksumSize")
                if base_name == checksum_name
                else context.get("finalSize")
            )
            if (
                base_status.st_dev != hidden_status.st_dev
                or base_status.st_ino != hidden_status.st_ino
                or base_status.st_nlink != 2
                or hidden_status.st_nlink != 2
                or hidden_sha != expected_hidden_sha
                or hidden_size != expected_hidden_size
            ):
                raise NotaryTransactionInspectionError(
                    "retained-publication-link-invalid"
                )
        final_after = os.fstat(final_descriptor)
        if (
            final_sha != context.get("finalSHA256")
            or final_size != context.get("finalSize")
            or checksum_sha != context.get("checksumSHA256")
            or checksum_size != context.get("checksumSize")
            or final_before.st_mtime_ns != final_after.st_mtime_ns
            or final_before.st_ctime_ns != final_after.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError(
                "final-artifact-mismatch"
            )
    finally:
        if final_descriptor >= 0:
            os.close(final_descriptor)
        if parent_descriptor >= 0:
            os.close(parent_descriptor)


def _record(
    *,
    category: str,
    name: str,
    status: str,
    stage: str | None,
    external_effect: str,
    structurally_safe: bool,
    release_blocking: bool,
    operator_action: bool,
    live_lease: bool | None,
    reason_code: str,
) -> InspectionRecord:
    return InspectionRecord(
        category=category,
        status=status,
        stage=stage,
        externalEffect=external_effect,
        structurallySafe=structurally_safe,
        releaseBlocking=release_blocking,
        operatorAction=operator_action,
        liveLease=live_lease,
        reasonCode=reason_code,
    )


def _classify_transaction(
    *,
    category: str,
    name: str,
    marker: dict[str, object] | None,
    stage: str | None,
    state_transaction_id: str | None,
    archive_name: str | None,
    expected_archive_name: str | None,
    live_lease: bool | None,
    reconciliation: dict[str, object] | None,
) -> InspectionRecord:
    marker_id = (
        str(marker["transactionId"]) if marker is not None else None
    )
    transaction_id = state_transaction_id or marker_id
    if (
        marker_id is not None
        and state_transaction_id is not None
        and marker_id != state_transaction_id
    ):
        raise NotaryTransactionInspectionError(
            "marker-state-id-mismatch"
        )
    if category == "initialization":
        if reconciliation is not None:
            raise NotaryTransactionInspectionError(
                "initialization-has-reconciliation"
            )
        match = _INITIAL_NAME.fullmatch(name)
        if match is None:
            raise NotaryTransactionInspectionError(
                "invalid-initialization-name"
            )
        if marker_id != match.group("id"):
            raise NotaryTransactionInspectionError(
                "marker-name-id-mismatch"
            )
        if stage not in {None, "transaction-created"}:
            raise NotaryTransactionInspectionError(
                "initialization-has-external-state"
            )
        return _record(
            category=category,
            name=name,
            status=(
                "initialization-live"
                if live_lease
                else "initialization-abandoned"
            ),
            stage=stage,
            external_effect="none",
            structurally_safe=True,
            release_blocking=True,
            operator_action=not bool(live_lease),
            live_lease=live_lease,
            reason_code=(
                "live-initialization-lease"
                if live_lease
                else "abandoned-before-external-effect"
            ),
        )
    if category == "active":
        match = _ACTIVE_NAME.fullmatch(name)
        if match is None or transaction_id != match.group("id"):
            raise NotaryTransactionInspectionError(
                "active-name-id-mismatch"
            )
        if stage is None:
            raise NotaryTransactionInspectionError(
                "active-state-missing"
            )
        if reconciliation is not None:
            if stage != "submit-intent":
                raise NotaryTransactionInspectionError(
                    "reconciliation-stage-mismatch"
                )
            return _record(
                category=category,
                name=name,
                status="active-reconciled-retirement-pending",
                stage=stage,
                external_effect="none",
                structurally_safe=True,
                release_blocking=True,
                operator_action=True,
                live_lease=None,
                reason_code="apple-history-proves-submission-absent",
            )
        if (
            expected_archive_name is None
            or archive_name != expected_archive_name
        ):
            return _record(
                category=category,
                name=name,
                status="active-candidate-mismatch",
                stage=stage,
                external_effect=(
                    "none"
                    if stage
                    in {"transaction-created", "submission-ready"}
                    else "possible"
                ),
                structurally_safe=True,
                release_blocking=True,
                operator_action=True,
                live_lease=None,
                reason_code="active-transaction-not-bound-to-candidate",
            )
        if stage == "submit-intent":
            return _record(
                category=category,
                name=name,
                status="active-manual-submit-reconciliation",
                stage=stage,
                external_effect="possible",
                structurally_safe=True,
                release_blocking=True,
                operator_action=True,
                live_lease=None,
                reason_code="apple-submission-id-unknown",
            )
        if stage in {"transaction-created", "submission-ready"}:
            return _record(
                category=category,
                name=name,
                status="active-pre-effect",
                stage=stage,
                external_effect="none",
                structurally_safe=True,
                release_blocking=True,
                operator_action=True,
                live_lease=None,
                reason_code="pre-effect-operator-reconciliation",
            )
        return _record(
            category=category,
            name=name,
            status="active-continuation-safe",
            stage=stage,
            external_effect="known",
            structurally_safe=True,
            release_blocking=False,
            operator_action=False,
            live_lease=None,
            reason_code="known-state-enters-exact-recovery-validation",
        )
    if category != "retired":
        raise NotaryTransactionInspectionError("invalid-category")
    retired_match = _RETIRED_NAME.fullmatch(name)
    if retired_match is None:
        raise NotaryTransactionInspectionError(
            "invalid-retired-name"
        )
    if reconciliation is not None:
        if stage != "submit-intent":
            raise NotaryTransactionInspectionError(
                "reconciliation-stage-mismatch"
            )
        return _record(
            category=category,
            name=name,
            status="retired-reconciled-no-effect",
            stage=stage,
            external_effect="none",
            structurally_safe=True,
            release_blocking=False,
            operator_action=False,
            live_lease=live_lease,
            reason_code="apple-history-proves-submission-absent",
        )
    if marker is None and stage is None:
        return _record(
            category=category,
            name=name,
            status="retired-incomplete-preactivation",
            stage=None,
            external_effect="none",
            structurally_safe=True,
            release_blocking=False,
            operator_action=False,
            live_lease=live_lease,
            reason_code="retained-before-marker",
        )
    if stage in {None, "transaction-created", "submission-ready"}:
        return _record(
            category=category,
            name=name,
            status="retired-pre-effect",
            stage=stage,
            external_effect="none",
            structurally_safe=True,
            release_blocking=False,
            operator_action=False,
            live_lease=live_lease,
            reason_code="retained-before-apple-effect",
        )
    if stage == "publication-complete":
        return _record(
            category=category,
            name=name,
            status="retired-complete",
            stage=stage,
            external_effect="known",
            structurally_safe=True,
            release_blocking=False,
            operator_action=False,
            live_lease=live_lease,
            reason_code="completed-transaction-retained",
        )
    return _record(
        category=category,
        name=name,
        status="retired-interrupted-after-effect",
        stage=stage,
        external_effect=(
            "possible" if stage == "submit-intent" else "known"
        ),
        structurally_safe=True,
        release_blocking=True,
        operator_action=True,
        live_lease=live_lease,
        reason_code="retired-state-requires-reconciliation",
    )


def _inspect_transaction_directory(
    parent: int,
    name: str,
    *,
    category: str,
    expected_device: int,
    expected_archive_name: str | None,
) -> InspectionRecord:
    descriptor = -1
    try:
        descriptor, before = _open_directory_at(
            parent,
            name,
            expected_device=expected_device,
        )
        names_before = _list_directory(
            descriptor,
            maximum=_MAXIMUM_ROOT_ENTRIES,
        )
        unknown = {
            name
            for name in names_before
            if (
                name not in _ALLOWED_ROOT_ENTRIES
                and _RESUME_NAME.fullmatch(name) is None
                and _ROOT_TEMPORARY_NAME.fullmatch(name) is None
            )
        }
        if unknown:
            raise NotaryTransactionInspectionError(
                "unknown-transaction-entry"
            )
        _validate_private_children(
            descriptor,
            names_before,
            expected_device=expected_device,
        )
        _validate_resume_directories(
            descriptor,
            names_before,
            expected_device=expected_device,
        )
        for entry_name in names_before:
            if _ROOT_TEMPORARY_NAME.fullmatch(entry_name):
                _validate_temporary_file_at(
                    descriptor,
                    entry_name,
                    expected_device=expected_device,
                    maximum_bytes=_MAXIMUM_RECEIPT_BYTES,
                )
        marker = (
            _read_marker(
                descriptor,
                expected_device=expected_device,
            )
            if ".init-marker.json" in names_before
            else None
        )
        if category != "retired" and marker is None:
            raise NotaryTransactionInspectionError(
                "marker-missing"
            )
        live_lease = (
            _lease_is_live(
                descriptor,
                expected_device=expected_device,
            )
            if ".init-lease" in names_before
            else None
        )
        if category == "initialization" and live_lease is None:
            raise NotaryTransactionInspectionError(
                "lease-missing"
            )
        (
            stage,
            state_transaction_id,
            _temporary_state,
            state_context,
        ) = (
            _read_state_chain(
                descriptor,
                expected_device=expected_device,
            )
        )
        reconciliation = (
            _read_reconciliation_marker(
                descriptor,
                expected_device=expected_device,
                transaction_id=state_transaction_id or "",
                state_context=state_context,
            )
            if "notary-reconciliation.json" in names_before
            else None
        )
        if stage is not None and not _REQUIRED_TRANSACTION_DIRECTORIES.issubset(
            names_before
        ):
            raise NotaryTransactionInspectionError(
                "required-transaction-directory-missing"
            )
        if marker is None and stage is None and any(
            name != ".init-lease"
            and _ROOT_TEMPORARY_NAME.fullmatch(name) is None
            for name in names_before
        ):
            raise NotaryTransactionInspectionError(
                "invalid-preactivation-retirement"
            )
        for metadata_name in (
            "apple-accepted.json",
            "notary-receipt.json",
        ):
            if metadata_name in names_before:
                _validate_regular_file_metadata_at(
                    descriptor,
                    metadata_name,
                    expected_device=expected_device,
                    expected_mode=0o400,
                    maximum_bytes=_MAXIMUM_RECEIPT_BYTES,
                )
        if category == "active" and stage is not None:
            _validate_active_artifacts(
                descriptor,
                stage=stage,
                context=state_context,
                expected_device=expected_device,
            )
        after = os.fstat(descriptor)
        names_after = _list_directory(
            descriptor,
            maximum=_MAXIMUM_ROOT_ENTRIES,
        )
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ctime_ns != after.st_ctime_ns
            or names_before != names_after
        ):
            raise NotaryTransactionInspectionError(
                "transaction-changed"
            )
        return _classify_transaction(
            category=category,
            name=name,
            marker=marker,
            stage=stage,
            state_transaction_id=state_transaction_id,
            archive_name=(
                state_context.get("archive")
                if isinstance(state_context.get("archive"), str)
                else None
            ),
            expected_archive_name=expected_archive_name,
            live_lease=live_lease,
            reconciliation=reconciliation,
        )
    except NotaryTransactionInspectionError as error:
        return _record(
            category=category,
            name=name,
            status=f"{category}-unsafe",
            stage=None,
            external_effect="unknown",
            structurally_safe=False,
            release_blocking=True,
            operator_action=True,
            live_lease=None,
            reason_code=str(error),
        )
    except OSError:
        return _record(
            category=category,
            name=name,
            status=f"{category}-unsafe",
            stage=None,
            external_effect="unknown",
            structurally_safe=False,
            release_blocking=True,
            operator_action=True,
            live_lease=None,
            reason_code="inspection-io-failure",
        )
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _inspect_release_locks(
    dist_descriptor: int,
    *,
    expected_device: int,
) -> tuple[InspectionRecord, ...]:
    descriptor = -1
    try:
        descriptor, before = _open_directory_at(
            dist_descriptor,
            ".notary-locks",
            expected_device=expected_device,
        )
        names = _list_directory(
            descriptor,
            maximum=_MAXIMUM_LOCK_ENTRIES,
        )
        allowed_archive_lock = re.compile(
            r"^\.NeAntik-[0-9]+\.[0-9]+\.[0-9]+"
            r"-arm64-notarized\.zip\.lock$"
        )
        if any(
            name != ".initialization.lock"
            and allowed_archive_lock.fullmatch(name) is None
            for name in names
        ):
            raise NotaryTransactionInspectionError(
                "unknown-release-lock"
            )
        live_count = 0
        for name in names:
            if _exclusive_lock_is_live(
                descriptor,
                name,
                expected_device=expected_device,
            ):
                live_count += 1
        after = os.fstat(descriptor)
        if (
            names
            != _list_directory(
                descriptor,
                maximum=_MAXIMUM_LOCK_ENTRIES,
            )
            or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ctime_ns != after.st_ctime_ns
        ):
            raise NotaryTransactionInspectionError(
                "release-lock-directory-changed"
            )
        if live_count:
            return (
                _record(
                    category="lock",
                    name="lock",
                    status="release-operation-live",
                    stage=None,
                    external_effect="possible",
                    structurally_safe=True,
                    release_blocking=True,
                    operator_action=False,
                    live_lease=True,
                    reason_code="exclusive-release-lock-held",
                ),
            )
        return ()
    except (OSError, NotaryTransactionInspectionError) as error:
        reason = (
            str(error)
            if isinstance(error, NotaryTransactionInspectionError)
            else "release-lock-inspection-failed"
        )
        return (
            _record(
                category="lock",
                name="lock",
                status="release-lock-unsafe",
                stage=None,
                external_effect="unknown",
                structurally_safe=False,
                release_blocking=True,
                operator_action=True,
                live_lease=None,
                reason_code=reason,
            ),
        )
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def inspect_dist(
    dist: Path,
    *,
    expected_archive_name: str | None = None,
) -> dict[str, object]:
    if (
        expected_archive_name is not None
        and _ARCHIVE.fullmatch(expected_archive_name) is None
    ):
        return _report(
            (
                _record(
                    category="dist",
                    name="dist",
                    status="candidate-archive-invalid",
                    stage=None,
                    external_effect="none",
                    structurally_safe=False,
                    release_blocking=True,
                    operator_action=True,
                    live_lease=None,
                    reason_code="expected-archive-name-invalid",
                ),
            )
        )
    dist = dist.absolute()
    if not os.path.lexists(dist):
        return _report(
            (
                _record(
                    category="dist",
                    name="dist",
                    status="dist-unavailable",
                    stage=None,
                    external_effect="none",
                    structurally_safe=True,
                    release_blocking=True,
                    operator_action=True,
                    live_lease=None,
                    reason_code="release-dist-missing",
                ),
            )
        )
    descriptor = -1
    retired_descriptor = -1
    records: list[InspectionRecord] = []
    try:
        descriptor = os.open(dist, _directory_flags())
        dist_status = _validate_directory(
            descriptor,
            expected_device=None,
            private=False,
        )
        names_before = _list_directory(
            descriptor,
            maximum=_MAXIMUM_DIST_ENTRIES,
        )
        for name in names_before:
            if name.startswith(".neantik-notary-init."):
                records.append(
                    _inspect_transaction_directory(
                        descriptor,
                        name,
                        category="initialization",
                        expected_device=dist_status.st_dev,
                        expected_archive_name=expected_archive_name,
                    )
                )
            elif name.startswith(".neantik-notary."):
                records.append(
                    _inspect_transaction_directory(
                        descriptor,
                        name,
                        category="active",
                        expected_device=dist_status.st_dev,
                        expected_archive_name=expected_archive_name,
                    )
                )
        active_count = sum(
            record.category == "active" for record in records
        )
        if active_count > 1:
            records.append(
                _record(
                    category="dist",
                    name="dist",
                    status="multiple-active-transactions",
                    stage=None,
                    external_effect="possible",
                    structurally_safe=True,
                    release_blocking=True,
                    operator_action=True,
                    live_lease=None,
                    reason_code="multiple-active-transactions",
                )
            )
        if ".notary-locks" in names_before:
            records.extend(
                _inspect_release_locks(
                    descriptor,
                    expected_device=dist_status.st_dev,
                )
            )
        if ".notary-retired" in names_before:
            retired_descriptor, retired_status = _open_directory_at(
                descriptor,
                ".notary-retired",
                expected_device=dist_status.st_dev,
            )
            retired_names = _list_directory(
                retired_descriptor,
                maximum=_MAXIMUM_RETIRED_ENTRIES,
            )
            for name in retired_names:
                if name == ".DS_Store":
                    continue
                records.append(
                    _inspect_transaction_directory(
                        retired_descriptor,
                        name,
                        category="retired",
                        expected_device=dist_status.st_dev,
                        expected_archive_name=expected_archive_name,
                    )
                )
            retired_names_after = _list_directory(
                retired_descriptor,
                maximum=_MAXIMUM_RETIRED_ENTRIES,
            )
            retired_after = os.fstat(retired_descriptor)
            if (
                retired_names != retired_names_after
                or retired_status.st_dev != retired_after.st_dev
                or retired_status.st_ino != retired_after.st_ino
                or retired_status.st_mtime_ns
                != retired_after.st_mtime_ns
                or retired_status.st_ctime_ns
                != retired_after.st_ctime_ns
            ):
                records.append(
                    _record(
                        category="dist",
                        name="retired",
                        status="retired-inventory-unstable",
                        stage=None,
                        external_effect="unknown",
                        structurally_safe=False,
                        release_blocking=True,
                        operator_action=True,
                        live_lease=None,
                        reason_code="retired-inventory-changed",
                    )
                )
        names_after = _list_directory(
            descriptor,
            maximum=_MAXIMUM_DIST_ENTRIES,
        )
        after = os.fstat(descriptor)
        if (
            names_before != names_after
            or dist_status.st_dev != after.st_dev
            or dist_status.st_ino != after.st_ino
            or dist_status.st_mtime_ns != after.st_mtime_ns
            or dist_status.st_ctime_ns != after.st_ctime_ns
        ):
            records.append(
                _record(
                    category="dist",
                    name="dist",
                    status="dist-unstable",
                    stage=None,
                    external_effect="unknown",
                    structurally_safe=False,
                    release_blocking=True,
                    operator_action=True,
                    live_lease=None,
                    reason_code="dist-changed",
                )
            )
    except (OSError, NotaryTransactionInspectionError) as error:
        reason = (
            str(error)
            if isinstance(error, NotaryTransactionInspectionError)
            else "inspection-io-failure"
        )
        records.append(
            _record(
                category="dist",
                name="dist",
                status="dist-unsafe",
                stage=None,
                external_effect="unknown",
                structurally_safe=False,
                release_blocking=True,
                operator_action=True,
                live_lease=None,
                reason_code=reason,
            )
        )
    finally:
        if retired_descriptor >= 0:
            os.close(retired_descriptor)
        if descriptor >= 0:
            os.close(descriptor)
    return _report(tuple(records))


def _report(
    records: tuple[InspectionRecord, ...],
) -> dict[str, object]:
    ordered = tuple(
        sorted(
            records,
            key=lambda record: (
                record.category,
                record.status,
                record.stage or "",
                record.reasonCode,
            ),
        )
    )
    reportable = tuple(
        record
        for record in ordered
        if (
            record.category != "retired"
            or not record.structurallySafe
            or record.releaseBlocking
            or record.operatorAction
        )
    )
    emitted = reportable[:_MAXIMUM_EMITTED_RECORDS]
    public_records: list[dict[str, object]] = []
    for record in emitted:
        payload = asdict(record)
        public_records.append(payload)
    unsafe_count = sum(
        not record.structurallySafe for record in ordered
    )
    blocking_count = sum(
        record.releaseBlocking for record in ordered
    )
    operator_count = sum(
        record.operatorAction for record in ordered
    )
    return {
        "schemaVersion": 1,
        "reportType": "neantik-notary-transaction-diagnostics",
        "project": "NeAntik",
        "readOnly": True,
        "privacy": {
            "rawPathsIncluded": False,
            "transactionIdsIncluded": False,
            "archiveNamesIncluded": False,
            "credentialsIncluded": False,
        },
        "safe": unsafe_count == 0,
        "releaseReady": blocking_count == 0,
        "summary": {
            "recordCount": len(ordered),
            "initializationCount": sum(
                record.category == "initialization"
                for record in ordered
            ),
            "activeCount": sum(
                record.category == "active"
                for record in ordered
            ),
            "retiredCount": sum(
                record.category == "retired"
                for record in ordered
            ),
            "unsafeCount": unsafe_count,
            "releaseBlockingCount": blocking_count,
            "operatorActionCount": operator_count,
            "reportedRecordCount": len(public_records),
            "recordsTruncated": len(reportable) > len(emitted),
        },
        "records": public_records,
    }


def format_report(report: dict[str, object]) -> str:
    summary = report["summary"]
    assert isinstance(summary, dict)
    lines = ["NeAntik — диагностика транзакций выпуска"]
    records = report["records"]
    assert isinstance(records, list)
    for record in records:
        assert isinstance(record, dict)
        if not record["structurallySafe"]:
            marker = "BLOCKED"
        elif record["releaseBlocking"]:
            marker = "WATCH"
        else:
            marker = "PASS"
        stage = (
            f"; этап {record['stage']}"
            if record.get("stage")
            else ""
        )
        lines.append(
            f"{marker}: {record['category']} "
            f"— {record['status']}{stage}"
        )
    if not records:
        retired_count = summary.get("retiredCount", 0)
        if retired_count:
            lines.append(
                "PASS: сохранена безопасная история транзакций: "
                f"{retired_count}; детали скрыты."
            )
        else:
            lines.append("PASS: локальных транзакций выпуска нет.")
    lines.append(
        "Итог: "
        f"записей {summary['recordCount']}, "
        f"требуют внимания {summary['operatorActionCount']}, "
        f"блокируют выпуск {summary['releaseBlockingCount']}."
    )
    lines.append(
        "Проверка только читает приватные метаданные; файлы не удаляются "
        "и не перемещаются."
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Read-only, privacy-safe NeAntik notarization transaction "
            "diagnostics."
        )
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--expected-archive-name",
        help=(
            "Exact NeAntik-X.Y.Z-arm64-notarized.zip candidate "
            "binding required before an active transaction can resume."
        ),
    )
    parser.add_argument(
        "--release-gate",
        action="store_true",
        help="Exit non-zero when a local transaction blocks a release.",
    )
    args = parser.parse_args()
    report = inspect_dist(
        args.project_root / "dist",
        expected_archive_name=args.expected_archive_name,
    )
    if args.json:
        print(
            json.dumps(
                report,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            )
        )
    else:
        print(format_report(report))
    if not report["safe"]:
        return 1
    if args.release_gate and not report["releaseReady"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
