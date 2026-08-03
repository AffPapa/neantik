#!/usr/bin/env python3
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import stat
import uuid
from dataclasses import dataclass
from pathlib import Path

import release_transaction as TRANSACTION


class NotaryTransactionStateError(RuntimeError):
    pass


STAGES: tuple[tuple[str, str], ...] = (
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
_STAGE_NAMES = tuple(name for _prefix, name in STAGES)
_MAXIMUM_STATE_BYTES = 4 * 1024 * 1024


@dataclass(frozen=True)
class StateReceipt:
    stage: str
    path: Path
    sha256: str
    payload: dict[str, object]


def canonical_json_bytes(payload: object) -> bytes:
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


def ensure_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    status = path.stat(follow_symlinks=False)
    if (
        not stat.S_ISDIR(status.st_mode)
        or path.is_symlink()
        or status.st_uid != os.geteuid()
        or stat.S_IMODE(status.st_mode) != 0o700
    ):
        raise NotaryTransactionStateError(
            "notary transaction state directory is unsafe"
        )


def acquire_transaction_lock(directory: Path, archive_name: str) -> int:
    ensure_private_directory(directory)
    if (
        not archive_name
        or Path(archive_name).name != archive_name
        or "\x00" in archive_name
    ):
        raise NotaryTransactionStateError(
            "notary transaction lock name is invalid"
        )
    lock_name = f".{archive_name}.lock"
    parent_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        parent_flags |= os.O_NOFOLLOW
    parent = os.open(directory, parent_flags)
    descriptor = -1
    try:
        flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(
            lock_name,
            flags,
            0o600,
            dir_fd=parent,
        )
        status = os.fstat(descriptor)
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_uid != os.geteuid()
            or status.st_nlink != 1
            or stat.S_IMODE(status.st_mode) != 0o600
        ):
            raise NotaryTransactionStateError(
                "notary transaction lock is unsafe"
            )
        try:
            fcntl.flock(
                descriptor,
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
        except BlockingIOError as error:
            raise NotaryTransactionStateError(
                "another notarization transaction is active"
            ) from error
        os.fsync(parent)
        return descriptor
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    finally:
        os.close(parent)


def _read_state_file(path: Path) -> tuple[dict[str, object], str]:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise NotaryTransactionStateError(
            "notary transaction state is unavailable"
        ) from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o400
            or before.st_size <= 0
            or before.st_size > _MAXIMUM_STATE_BYTES
        ):
            raise NotaryTransactionStateError(
                "notary transaction state file is unsafe"
            )
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > _MAXIMUM_STATE_BYTES:
                raise NotaryTransactionStateError(
                    "notary transaction state file is too large"
                )
            chunks.append(chunk)
        raw = b"".join(chunks)
        after = os.fstat(descriptor)
    except OSError as error:
        raise NotaryTransactionStateError(
            "notary transaction state could not be read"
        ) from error
    finally:
        os.close(descriptor)
    if (
        len(raw) != before.st_size
        or before.st_dev != after.st_dev
        or before.st_ino != after.st_ino
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
    ):
        raise NotaryTransactionStateError(
            "notary transaction state changed while reading"
        )

    def reject_duplicates(
        pairs: list[tuple[str, object]],
    ) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise NotaryTransactionStateError(
                    "notary transaction state contains duplicate keys"
                )
            result[key] = value
        return result

    try:
        payload = json.loads(
            raw,
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                NotaryTransactionStateError(
                    f"non-finite JSON value is forbidden: {value}"
                )
            ),
        )
    except (
        json.JSONDecodeError,
        UnicodeDecodeError,
        ValueError,
    ) as error:
        raise NotaryTransactionStateError(
            "notary transaction state is invalid JSON"
        ) from error
    if (
        not isinstance(payload, dict)
        or set(payload)
        != {
            "data",
            "previousReceiptSHA256",
            "schemaVersion",
            "state",
            "transactionId",
        }
        or payload.get("schemaVersion") != 1
        or not isinstance(payload.get("data"), dict)
        or canonical_json_bytes(payload) != raw
    ):
        raise NotaryTransactionStateError(
            "notary transaction state schema is invalid"
        )
    return payload, hashlib.sha256(raw).hexdigest()


class StateStore:
    def __init__(self, root: Path, transaction_id: str) -> None:
        try:
            normalized = str(uuid.UUID(transaction_id))
        except (ValueError, AttributeError) as error:
            raise NotaryTransactionStateError(
                "notary transaction identifier is invalid"
            ) from error
        if normalized != transaction_id:
            raise NotaryTransactionStateError(
                "notary transaction identifier is non-canonical"
            )
        self.root = root.absolute()
        self.transaction_id = transaction_id
        self.state = self.root / "state"
        ensure_private_directory(self.root)
        ensure_private_directory(self.state)

    def load(self) -> tuple[StateReceipt, ...]:
        names = sorted(os.listdir(self.state))
        hidden_names = [
            name
            for name in names
            if name.startswith(".")
        ]
        if any(
            re.fullmatch(
                r"\.[0-9]{2}-[a-z-]+\.[0-9a-f]{64}\.json"
                r"\.tmp-[0-9a-f]{32}",
                name,
            )
            is None
            for name in hidden_names
        ):
            raise NotaryTransactionStateError(
                "notary transaction state contains an unknown hidden file"
            )
        final_names = [
            name
            for name in names
            if not name.startswith(".")
        ]
        if len(final_names) > len(STAGES):
            raise NotaryTransactionStateError(
                "notary transaction state sequence is invalid"
            )
        receipts: list[StateReceipt] = []
        previous: str | None = None
        for (prefix, expected_stage), name in zip(
            STAGES,
            final_names,
            strict=False,
        ):
            match = re.fullmatch(
                rf"{prefix}-{re.escape(expected_stage)}"
                r"\.([0-9a-f]{64})\.json",
                name,
            )
            if match is None:
                raise NotaryTransactionStateError(
                    "notary transaction state sequence is invalid"
                )
            payload, digest = _read_state_file(self.state / name)
            if (
                digest != match.group(1)
                or
                payload.get("transactionId") != self.transaction_id
                or payload.get("state") != expected_stage
                or payload.get("previousReceiptSHA256") != previous
            ):
                raise NotaryTransactionStateError(
                    "notary transaction state chain is invalid"
                )
            receipts.append(
                StateReceipt(
                    stage=expected_stage,
                    path=self.state / name,
                    sha256=digest,
                    payload=payload,
                )
            )
            previous = digest
        return tuple(receipts)

    def commit(
        self,
        stage: str,
        data: dict[str, object],
    ) -> StateReceipt:
        if stage not in _STAGE_NAMES:
            raise NotaryTransactionStateError(
                "notary transaction state name is invalid"
            )
        existing = self.load()
        expected_index = len(existing)
        if expected_index >= len(STAGES) or STAGES[expected_index][1] != stage:
            raise NotaryTransactionStateError(
                "notary transaction state transition is invalid"
            )
        previous = existing[-1].sha256 if existing else None
        payload: dict[str, object] = {
            "schemaVersion": 1,
            "transactionId": self.transaction_id,
            "state": stage,
            "previousReceiptSHA256": previous,
            "data": data,
        }
        try:
            encoded = canonical_json_bytes(payload)
        except (TypeError, ValueError) as error:
            raise NotaryTransactionStateError(
                "notary transaction state is not canonical JSON"
            ) from error
        receipt_digest = hashlib.sha256(encoded).hexdigest()
        prefix = STAGES[expected_index][0]
        final_name = f"{prefix}-{stage}.{receipt_digest}.json"
        temporary_name = f".{final_name}.tmp-{uuid.uuid4().hex}"
        parent_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            parent_flags |= os.O_NOFOLLOW
        parent = os.open(self.state, parent_flags)
        descriptor = -1
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(
                temporary_name,
                flags,
                0o600,
                dir_fd=parent,
            )
            view = memoryview(encoded)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise NotaryTransactionStateError(
                        "notary transaction state write failed"
                    )
                view = view[written:]
            os.fsync(descriptor)
            os.fchmod(descriptor, 0o400)
            os.fsync(descriptor)
            status = os.fstat(descriptor)
            if (
                status.st_size != len(encoded)
                or stat.S_IMODE(status.st_mode) != 0o400
                or status.st_nlink != 1
            ):
                raise NotaryTransactionStateError(
                    "notary transaction state write failed"
                )
            TRANSACTION._rename_exclusive(
                parent,
                temporary_name,
                parent,
                final_name,
            )
            os.fsync(parent)
        except OSError as error:
            raise NotaryTransactionStateError(
                "notary transaction state write failed"
            ) from error
        finally:
            for open_descriptor in (descriptor, parent):
                if open_descriptor >= 0:
                    try:
                        os.close(open_descriptor)
                    except OSError:
                        pass
        loaded = self.load()
        if len(loaded) != expected_index + 1:
            raise NotaryTransactionStateError(
                "notary transaction state commit was not durable"
            )
        return loaded[-1]


def find_active_transaction(
    dist: Path,
    archive_name: str,
    *,
    exclude: Path | None = None,
) -> tuple[Path, tuple[StateReceipt, ...]] | None:
    matches: list[tuple[Path, tuple[StateReceipt, ...]]] = []
    for candidate in sorted(dist.glob(".neantik-notary.*")):
        if exclude is not None and candidate == exclude:
            continue
        try:
            status = candidate.stat(follow_symlinks=False)
        except OSError as error:
            raise NotaryTransactionStateError(
                "unfinished notary transaction is unavailable"
            ) from error
        if (
            candidate.is_symlink()
            or not stat.S_ISDIR(status.st_mode)
            or status.st_uid != os.geteuid()
            or stat.S_IMODE(status.st_mode) != 0o700
        ):
            raise NotaryTransactionStateError(
                "unfinished notary transaction is unsafe"
            )
        state_directory = candidate / "state"
        if not state_directory.exists():
            raise NotaryTransactionStateError(
                "unfinished notary transaction has no durable state"
            )
        state_names = sorted(
            name
            for name in os.listdir(state_directory)
            if not name.startswith(".")
        )
        if not state_names:
            raise NotaryTransactionStateError(
                "unfinished notary transaction has no durable state"
            )
        first_payload, _digest = _read_state_file(
            state_directory / state_names[0]
        )
        transaction_id = first_payload.get("transactionId")
        if not isinstance(transaction_id, str):
            raise NotaryTransactionStateError(
                "unfinished notary transaction id is invalid"
            )
        store = StateStore(candidate, transaction_id)
        receipts = store.load()
        first_data = receipts[0].payload["data"]
        if (
            isinstance(first_data, dict)
            and first_data.get("archiveName") == archive_name
        ):
            matches.append((candidate, receipts))
    if len(matches) > 1:
        raise NotaryTransactionStateError(
            "multiple unfinished notarization transactions require reconciliation"
        )
    return matches[0] if matches else None
