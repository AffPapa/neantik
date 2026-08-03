#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import stat
from dataclasses import dataclass
from pathlib import Path


class ReleaseInputSnapshotError(RuntimeError):
    pass


@dataclass(frozen=True)
class ReleaseInputSnapshot:
    source: Path
    pinned: Path
    sha256: str
    size: int
    device: int
    inode: int
    mtime_ns: int
    ctime_ns: int
    pinned_device: int
    pinned_inode: int
    pinned_mtime_ns: int
    pinned_ctime_ns: int


def _safe_source_descriptor(path: Path) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ReleaseInputSnapshotError("release input is unavailable") from error
    try:
        status = os.fstat(descriptor)
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_uid != os.geteuid()
            or status.st_nlink != 1
            or status.st_mode & 0o022
            or status.st_size <= 0
        ):
            raise ReleaseInputSnapshotError("release input is unsafe")
        return descriptor, status
    except Exception:
        os.close(descriptor)
        raise


def _unchanged(before: os.stat_result, after: os.stat_result) -> bool:
    return (
        before.st_dev == after.st_dev
        and before.st_ino == after.st_ino
        and before.st_nlink == after.st_nlink
        and before.st_size == after.st_size
        and before.st_mtime_ns == after.st_mtime_ns
        and before.st_ctime_ns == after.st_ctime_ns
    )


def snapshot_release_input(
    source: Path,
    destination: Path,
    *,
    maximum_bytes: int,
) -> ReleaseInputSnapshot:
    if maximum_bytes <= 0:
        raise ValueError("maximum_bytes must be positive")
    source = source.absolute()
    destination = destination.absolute()
    descriptor, before = _safe_source_descriptor(source)
    if before.st_size > maximum_bytes:
        os.close(descriptor)
        raise ReleaseInputSnapshotError("release input exceeds its size limit")

    parent = destination.parent
    parent_status = parent.stat()
    if (
        not stat.S_ISDIR(parent_status.st_mode)
        or parent_status.st_uid != os.geteuid()
        or parent_status.st_mode & 0o077
    ):
        os.close(descriptor)
        raise ReleaseInputSnapshotError("snapshot directory is unsafe")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        output = os.open(destination, flags, 0o600)
    except OSError as error:
        os.close(descriptor)
        raise ReleaseInputSnapshotError("snapshot output is unavailable") from error

    digest = hashlib.sha256()
    total = 0
    succeeded = False
    try:
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise ReleaseInputSnapshotError(
                    "release input exceeds its size limit"
                )
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(output, view)
                if written <= 0:
                    raise ReleaseInputSnapshotError("snapshot write failed")
                view = view[written:]
        os.fsync(output)
        after = os.fstat(descriptor)
        if not _unchanged(before, after) or total != after.st_size:
            raise ReleaseInputSnapshotError("release input changed during snapshot")
        succeeded = True
    except OSError as error:
        raise ReleaseInputSnapshotError("release input snapshot failed") from error
    finally:
        os.close(output)
        os.close(descriptor)
        if not succeeded:
            try:
                destination.unlink()
            except FileNotFoundError:
                pass

    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    pinned_descriptor, pinned_status = _safe_source_descriptor(destination)
    os.close(pinned_descriptor)
    if (
        not stat.S_ISREG(pinned_status.st_mode)
        or pinned_status.st_uid != os.geteuid()
        or pinned_status.st_nlink != 1
        or stat.S_IMODE(pinned_status.st_mode) != 0o600
        or pinned_status.st_size != total
    ):
        raise ReleaseInputSnapshotError("snapshot output is unsafe")
    return ReleaseInputSnapshot(
        source=source,
        pinned=destination,
        sha256=digest.hexdigest(),
        size=total,
        device=before.st_dev,
        inode=before.st_ino,
        mtime_ns=before.st_mtime_ns,
        ctime_ns=before.st_ctime_ns,
        pinned_device=pinned_status.st_dev,
        pinned_inode=pinned_status.st_ino,
        pinned_mtime_ns=pinned_status.st_mtime_ns,
        pinned_ctime_ns=pinned_status.st_ctime_ns,
    )


def assert_snapshot_source_unchanged(
    snapshot: ReleaseInputSnapshot,
    *,
    maximum_bytes: int,
) -> None:
    _assert_snapshot_path_unchanged(
        snapshot.source,
        snapshot,
        maximum_bytes=maximum_bytes,
        use_source_identity=True,
        error_message="release input changed after snapshot",
    )


def assert_snapshot_copy_unchanged(
    snapshot: ReleaseInputSnapshot,
    *,
    maximum_bytes: int,
) -> None:
    _assert_snapshot_path_unchanged(
        snapshot.pinned,
        snapshot,
        maximum_bytes=maximum_bytes,
        use_source_identity=False,
        error_message="pinned release input changed during verification",
    )


def _assert_snapshot_path_unchanged(
    path: Path,
    snapshot: ReleaseInputSnapshot,
    *,
    maximum_bytes: int,
    use_source_identity: bool,
    error_message: str,
) -> None:
    descriptor, before = _safe_source_descriptor(path)
    try:
        if before.st_size > maximum_bytes:
            raise ReleaseInputSnapshotError("release input exceeds its size limit")
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise ReleaseInputSnapshotError(
                    "release input exceeds its size limit"
                )
            digest.update(chunk)
        after = os.fstat(descriptor)
    except OSError as error:
        raise ReleaseInputSnapshotError("release input recheck failed") from error
    finally:
        os.close(descriptor)
    expected_identity = (
        (
            snapshot.device,
            snapshot.inode,
            snapshot.mtime_ns,
            snapshot.ctime_ns,
        )
        if use_source_identity
        else (
            snapshot.pinned_device,
            snapshot.pinned_inode,
            snapshot.pinned_mtime_ns,
            snapshot.pinned_ctime_ns,
        )
    )
    if (
        not _unchanged(before, after)
        or before.st_dev != expected_identity[0]
        or before.st_ino != expected_identity[1]
        or before.st_mtime_ns != expected_identity[2]
        or before.st_ctime_ns != expected_identity[3]
        or total != snapshot.size
        or digest.hexdigest() != snapshot.sha256
    ):
        raise ReleaseInputSnapshotError(error_message)
