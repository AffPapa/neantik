#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import ctypes
import errno
import os
import re
import select
import stat
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, TypeVar


class ReleaseTransactionError(RuntimeError):
    pass


@dataclass(frozen=True)
class FileSeal:
    path: Path
    sha256: str
    size: int
    device: int
    inode: int
    mtime_ns: int
    ctime_ns: int
    uid: int
    mode: int


_T = TypeVar("_T")
_CHUNK_BYTES = 1024 * 1024


def _directory_descriptor(path: Path, *, private: bool) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ReleaseTransactionError(
            "release transaction directory is unavailable"
        ) from error
    try:
        status = os.fstat(descriptor)
    except OSError as error:
        os.close(descriptor)
        raise ReleaseTransactionError(
            "release transaction directory is unavailable"
        ) from error
    unsafe_mode = (
        status.st_mode & 0o077 if private else status.st_mode & 0o022
    )
    if (
        not stat.S_ISDIR(status.st_mode)
        or status.st_uid != os.geteuid()
        or unsafe_mode
    ):
        os.close(descriptor)
        raise ReleaseTransactionError(
            "release transaction directory is unsafe"
        )
    return descriptor


def _regular_file_descriptor(
    path: Path,
    *,
    maximum_bytes: int,
) -> tuple[int, os.stat_result]:
    if maximum_bytes <= 0:
        raise ValueError("maximum_bytes must be positive")
    parent = _directory_descriptor(path.parent, private=False)
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path.name, flags, dir_fd=parent)
    except OSError as error:
        os.close(parent)
        raise ReleaseTransactionError(
            "release transaction file is unavailable"
        ) from error
    finally:
        if "descriptor" in locals():
            os.close(parent)
    try:
        status = os.fstat(descriptor)
    except OSError as error:
        os.close(descriptor)
        raise ReleaseTransactionError(
            "release transaction file is unavailable"
        ) from error
    if (
        not stat.S_ISREG(status.st_mode)
        or status.st_uid != os.geteuid()
        or status.st_nlink < 1
        or stat.S_IMODE(status.st_mode) not in {0o400, 0o600}
        or status.st_size <= 0
        or status.st_size > maximum_bytes
    ):
        os.close(descriptor)
        raise ReleaseTransactionError(
            "release transaction file is unsafe"
        )
    return descriptor, status


def _identity(status: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        status.st_dev,
        status.st_ino,
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
        stat.S_IMODE(status.st_mode),
    )


def _hash_descriptor(
    descriptor: int,
    *,
    maximum_bytes: int,
) -> tuple[str, int]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(descriptor, _CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > maximum_bytes:
            raise ReleaseTransactionError(
                "release transaction file exceeds its size limit"
            )
        digest.update(chunk)
    return digest.hexdigest(), total


def seal_regular_file(
    path: Path,
    *,
    maximum_bytes: int,
    allowed_link_counts: frozenset[int] = frozenset({1}),
) -> FileSeal:
    path = path.absolute()
    descriptor, before = _regular_file_descriptor(
        path,
        maximum_bytes=maximum_bytes,
    )
    try:
        digest, total = _hash_descriptor(
            descriptor,
            maximum_bytes=maximum_bytes,
        )
        after = os.fstat(descriptor)
    except OSError as error:
        raise ReleaseTransactionError(
            "release transaction file could not be sealed"
        ) from error
    finally:
        os.close(descriptor)
    if (
        _identity(before) != _identity(after)
        or before.st_nlink not in allowed_link_counts
        or after.st_nlink not in allowed_link_counts
        or total != after.st_size
    ):
        raise ReleaseTransactionError(
            "release transaction file changed while sealing"
        )
    return FileSeal(
        path=path,
        sha256=digest,
        size=total,
        device=before.st_dev,
        inode=before.st_ino,
        mtime_ns=before.st_mtime_ns,
        ctime_ns=before.st_ctime_ns,
        uid=before.st_uid,
        mode=stat.S_IMODE(before.st_mode),
    )


def publish_or_adopt_sealed_file(
    seal: FileSeal,
    *,
    destination: Path,
    maximum_bytes: int,
) -> tuple[int, int]:
    destination = destination.absolute()
    if destination.name != seal.path.name:
        raise ReleaseTransactionError(
            "release destination does not match the sealed file"
        )
    for path in (seal.path, destination):
        normalized = Path(os.path.normpath(str(path.absolute())))
        if path.absolute() != normalized:
            raise ReleaseTransactionError(
                "release publication paths must be normalized"
            )
    destination_parent = -1
    source_parent = -1
    source_descriptor = -1
    try:
        destination_parent = _directory_descriptor(
            destination.parent,
            private=False,
        )
        source_parent = _directory_descriptor(
            seal.path.parent,
            private=True,
        )
        source_descriptor = os.open(
            seal.path.name,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=source_parent,
        )
        if os.fstat(source_descriptor).st_dev != os.fstat(
            destination_parent
        ).st_dev:
            raise ReleaseTransactionError(
                "release transaction and destination are on different filesystems"
            )
        try:
            existing = os.stat(
                destination.name,
                dir_fd=destination_parent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            source_status = os.fstat(source_descriptor)
            if source_status.st_nlink == 1:
                identity = _publish_one_file(
                    source_parent=source_parent,
                    source_name=seal.path.name,
                    source_descriptor=source_descriptor,
                    seal=seal,
                    destination_parent=destination_parent,
                    destination_name=destination.name,
                    maximum_bytes=maximum_bytes,
                )
            elif source_status.st_nlink == 2:
                identity = _adopt_retained_staging_link(
                    source_parent=source_parent,
                    source_descriptor=source_descriptor,
                    seal=seal,
                    destination_parent=destination_parent,
                    destination_name=destination.name,
                    maximum_bytes=maximum_bytes,
                )
            else:
                raise ReleaseTransactionError(
                    "retained release artifact has an unexpected link count"
                )
        else:
            identity = (existing.st_dev, existing.st_ino)
            source_status = os.fstat(source_descriptor)
            if identity != (
                source_status.st_dev,
                source_status.st_ino,
            ):
                raise ReleaseTransactionError(
                    "release destination exists but is not the retained "
                    "transaction artifact"
                )
            _assert_descriptor_matches_seal(
                source_descriptor,
                seal,
                maximum_bytes=maximum_bytes,
                expected_link_count=2,
                exact_times=False,
            )
        _assert_public_destination(
            parent=destination_parent,
            name=destination.name,
            seal=seal,
            identity=identity,
            maximum_bytes=maximum_bytes,
        )
        os.fsync(destination_parent)
        return identity
    except FileExistsError as error:
        raise ReleaseTransactionError(
            "release destination already exists"
        ) from error
    finally:
        for descriptor in (
            source_descriptor,
            source_parent,
            destination_parent,
        ):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass


def assert_sealed(
    seal: FileSeal,
    *,
    maximum_bytes: int,
    allowed_link_counts: frozenset[int] = frozenset({1}),
) -> None:
    descriptor, before = _regular_file_descriptor(
        seal.path,
        maximum_bytes=maximum_bytes,
    )
    try:
        digest, total = _hash_descriptor(
            descriptor,
            maximum_bytes=maximum_bytes,
        )
        after = os.fstat(descriptor)
    except OSError as error:
        raise ReleaseTransactionError(
            "sealed release file could not be rechecked"
        ) from error
    finally:
        os.close(descriptor)
    expected = (
        seal.device,
        seal.inode,
        seal.size,
        seal.mtime_ns,
        seal.ctime_ns,
        seal.mode,
    )
    if (
        _identity(before) != _identity(after)
        or _identity(before) != expected
        or before.st_uid != seal.uid
        or before.st_nlink not in allowed_link_counts
        or total != seal.size
        or digest != seal.sha256
    ):
        raise ReleaseTransactionError(
            "sealed release file changed during the transaction"
        )


def observe_sealed_phase(
    seal: FileSeal,
    action: Callable[[], _T],
    *,
    maximum_bytes: int,
    allowed_link_counts: frozenset[int] = frozenset({1}),
) -> _T:
    descriptor, before = _regular_file_descriptor(
        seal.path,
        maximum_bytes=maximum_bytes,
    )
    queue = None
    try:
        expected = (
            seal.device,
            seal.inode,
            seal.size,
            seal.mtime_ns,
            seal.ctime_ns,
            seal.mode,
        )
        if (
            _identity(before) != expected
            or before.st_nlink not in allowed_link_counts
        ):
            raise ReleaseTransactionError(
                "sealed release file changed before the external phase"
            )
        if not hasattr(select, "kqueue"):
            raise ReleaseTransactionError(
                "macOS kqueue is required for release transactions"
            )
        queue = select.kqueue()
        vnode_flags = (
            select.KQ_NOTE_WRITE
            | select.KQ_NOTE_EXTEND
            | select.KQ_NOTE_ATTRIB
            | select.KQ_NOTE_LINK
            | select.KQ_NOTE_RENAME
            | select.KQ_NOTE_DELETE
            | select.KQ_NOTE_REVOKE
        )
        queue.control(
            [
                select.kevent(
                    descriptor,
                    filter=select.KQ_FILTER_VNODE,
                    flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                    fflags=vnode_flags,
                )
            ],
            0,
            0,
        )
        action_error: BaseException | None = None
        result: _T | None = None
        try:
            result = action()
        except BaseException as error:
            action_error = error
        events = queue.control(None, 8, 0)
        digest, total = _hash_descriptor(
            descriptor,
            maximum_bytes=maximum_bytes,
        )
        after = os.fstat(descriptor)
        path_status = seal.path.stat(follow_symlinks=False)
        if (
            _identity(before) != _identity(after)
            or after.st_nlink not in allowed_link_counts
            or path_status.st_dev != seal.device
            or path_status.st_ino != seal.inode
            or digest != seal.sha256
            or total != seal.size
        ):
            raise ReleaseTransactionError(
                "sealed release file changed during the external phase"
            ) from action_error
        if events:
            # macOS may emit vnode attribute events for metadata/provenance
            # updates around notarized archives. Treat the event as a signal
            # to re-check the sealed file, not as proof of content mutation:
            # identity, link count, size, mtime/ctime and SHA-256 remain the
            # security boundary.
            assert_sealed(
                seal,
                maximum_bytes=maximum_bytes,
                allowed_link_counts=allowed_link_counts,
            )
        if action_error is not None:
            raise action_error
        return result  # type: ignore[return-value]
    except OSError as error:
        raise ReleaseTransactionError(
            "sealed release phase could not be observed"
        ) from error
    finally:
        try:
            if queue is not None:
                queue.close()
        finally:
            os.close(descriptor)


def write_checksum_sidecar(
    archive: FileSeal,
    destination: Path,
) -> FileSeal:
    destination = destination.absolute()
    parent = _directory_descriptor(destination.parent, private=True)
    temporary_name = (
        f".{destination.name}.neantik-write-{uuid.uuid4().hex}"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    payload = (
        f"{archive.sha256}  {archive.path.name}\n".encode("utf-8")
    )
    output = -1
    try:
        try:
            output = os.open(
                temporary_name,
                flags,
                0o600,
                dir_fd=parent,
            )
        except OSError as error:
            raise ReleaseTransactionError(
                "release checksum output is unavailable"
            ) from error
        try:
            view = memoryview(payload)
            while view:
                written = os.write(output, view)
                if written <= 0:
                    raise ReleaseTransactionError(
                        "release checksum write failed"
                    )
                view = view[written:]
            os.fsync(output)
        except OSError as error:
            raise ReleaseTransactionError(
                "release checksum write failed"
            ) from error
        finally:
            os.close(output)
            output = -1
        try:
            _rename_exclusive(
                parent,
                temporary_name,
                parent,
                destination.name,
            )
            os.fsync(parent)
        except OSError as error:
            raise ReleaseTransactionError(
                "release checksum commit failed"
            ) from error
    finally:
        if output >= 0:
            try:
                os.close(output)
            except OSError:
                pass
        os.close(parent)
    return seal_regular_file(
        destination,
        maximum_bytes=4 * 1024,
    )


def assert_checksum_matches_archive(
    archive: FileSeal,
    checksum: FileSeal,
) -> None:
    descriptor, _status = _regular_file_descriptor(
        checksum.path,
        maximum_bytes=4 * 1024,
    )
    try:
        digest, size = _hash_descriptor(
            descriptor,
            maximum_bytes=4 * 1024,
        )
    finally:
        os.close(descriptor)
    expected = (
        f"{archive.sha256}  {archive.path.name}\n".encode("utf-8")
    )
    if (
        size != len(expected)
        or digest != hashlib.sha256(expected).hexdigest()
        or checksum.sha256 != digest
        or checksum.size != size
    ):
        raise ReleaseTransactionError(
            "release checksum does not match the sealed archive"
        )


def _rename_exclusive(
    source_parent: int,
    source_name: str,
    destination_parent: int,
    destination_name: str,
) -> None:
    try:
        function = ctypes.CDLL(
            None,
            use_errno=True,
        ).renameatx_np
    except AttributeError as error:
        raise ReleaseTransactionError(
            "macOS renameatx_np is required for release publication"
        ) from error
    function.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    function.restype = ctypes.c_int
    rename_exclusive = 0x00000004
    result = function(
        source_parent,
        os.fsencode(source_name),
        destination_parent,
        os.fsencode(destination_name),
        rename_exclusive,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        raise FileExistsError(destination_name)
    raise OSError(error_number, os.strerror(error_number))


def _assert_descriptor_matches_seal(
    descriptor: int,
    seal: FileSeal,
    *,
    maximum_bytes: int,
    expected_link_count: int,
    exact_times: bool,
) -> None:
    before = os.fstat(descriptor)
    digest, total = _hash_descriptor(
        descriptor,
        maximum_bytes=maximum_bytes,
    )
    after = os.fstat(descriptor)
    times_match = (
        before.st_mtime_ns == seal.mtime_ns
        and before.st_ctime_ns == seal.ctime_ns
    )
    if (
        _identity(before) != _identity(after)
        or before.st_dev != seal.device
        or before.st_ino != seal.inode
        or before.st_uid != seal.uid
        or stat.S_IMODE(before.st_mode) != seal.mode
        or before.st_nlink != expected_link_count
        or total != seal.size
        or digest != seal.sha256
        or (exact_times and not times_match)
    ):
        raise ReleaseTransactionError(
            "release file changed immediately before publication"
        )


def _publish_one_file(
    *,
    source_parent: int,
    source_name: str,
    source_descriptor: int,
    seal: FileSeal,
    destination_parent: int,
    destination_name: str,
    maximum_bytes: int,
) -> tuple[int, int]:
    _assert_descriptor_matches_seal(
        source_descriptor,
        seal,
        maximum_bytes=maximum_bytes,
        expected_link_count=1,
        exact_times=True,
    )
    # Keep the pre-commit hard link inside the private transaction directory.
    # A descriptor/open failure must never strand a hidden artifact in the
    # public destination. renameatx_np can atomically commit across two
    # directories on the same filesystem.
    hidden_name = (
        f".{destination_name}.neantik-publish-{uuid.uuid4().hex}"
    )
    final_identity: tuple[int, int] | None = None
    try:
        os.link(
            source_name,
            hidden_name,
            src_dir_fd=source_parent,
            dst_dir_fd=source_parent,
            follow_symlinks=False,
        )
        linked_status = os.stat(
            hidden_name,
            dir_fd=source_parent,
            follow_symlinks=False,
        )
        source_status = os.fstat(source_descriptor)
        if (
            linked_status.st_dev != source_status.st_dev
            or linked_status.st_ino != source_status.st_ino
        ):
            raise ReleaseTransactionError(
                "release staging link does not match the sealed source"
            )
        hidden_descriptor = os.open(
            hidden_name,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=source_parent,
        )
        try:
            hidden_status = os.fstat(hidden_descriptor)
            _assert_descriptor_matches_seal(
                hidden_descriptor,
                seal,
                maximum_bytes=maximum_bytes,
                expected_link_count=2,
                exact_times=False,
            )
        finally:
            os.close(hidden_descriptor)
        _rename_exclusive(
            source_parent,
            hidden_name,
            destination_parent,
            destination_name,
        )
        final_status = os.stat(
            destination_name,
            dir_fd=destination_parent,
            follow_symlinks=False,
        )
        final_identity = (
            final_status.st_dev,
            final_status.st_ino,
        )
        final_descriptor = os.open(
            destination_name,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=destination_parent,
        )
        try:
            _assert_descriptor_matches_seal(
                final_descriptor,
                seal,
                maximum_bytes=maximum_bytes,
                expected_link_count=2,
                exact_times=False,
            )
        finally:
            os.close(final_descriptor)
        os.fsync(destination_parent)
        assert final_identity is not None
        return final_identity
    except BaseException:
        # The hidden link is intentionally retained. Darwin cannot unlink an
        # already-open inode, so stat-then-unlink would be vulnerable to a
        # same-user name swap. A later recovery pass may adopt only the exact
        # sealed inode; anything else remains for operator reconciliation.
        # A committed public name is never moved or deleted here. It may have
        # been replaced after the commit; retaining it and failing closed is
        # safer than touching an inode that is no longer proven to be ours.
        try:
            os.fsync(destination_parent)
        except OSError:
            pass
        raise


def _adopt_retained_staging_link(
    *,
    source_parent: int,
    source_descriptor: int,
    seal: FileSeal,
    destination_parent: int,
    destination_name: str,
    maximum_bytes: int,
) -> tuple[int, int]:
    prefix = f".{destination_name}.neantik-publish-"
    candidates = [
        name
        for name in os.listdir(source_parent)
        if name.startswith(prefix)
        and re.fullmatch(
            re.escape(prefix) + r"[0-9a-f]{32}",
            name,
        )
    ]
    if len(candidates) != 1:
        raise ReleaseTransactionError(
            "retained release staging link is missing or ambiguous"
        )
    hidden_name = candidates[0]
    hidden_descriptor = os.open(
        hidden_name,
        os.O_RDONLY
        | os.O_CLOEXEC
        | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=source_parent,
    )
    try:
        source_status = os.fstat(source_descriptor)
        hidden_status = os.fstat(hidden_descriptor)
        if (
            source_status.st_dev != hidden_status.st_dev
            or source_status.st_ino != hidden_status.st_ino
        ):
            raise ReleaseTransactionError(
                "retained release staging link has a foreign identity"
            )
        _assert_descriptor_matches_seal(
            hidden_descriptor,
            seal,
            maximum_bytes=maximum_bytes,
            expected_link_count=2,
            exact_times=False,
        )
    finally:
        os.close(hidden_descriptor)
    _rename_exclusive(
        source_parent,
        hidden_name,
        destination_parent,
        destination_name,
    )
    final_status = os.stat(
        destination_name,
        dir_fd=destination_parent,
        follow_symlinks=False,
    )
    identity = (final_status.st_dev, final_status.st_ino)
    if identity != (seal.device, seal.inode):
        raise ReleaseTransactionError(
            "retained release staging link changed during adoption"
        )
    os.fsync(source_parent)
    os.fsync(destination_parent)
    return identity


def _assert_public_destination(
    *,
    parent: int,
    name: str,
    seal: FileSeal,
    identity: tuple[int, int],
    maximum_bytes: int,
) -> None:
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent,
    )
    try:
        status = os.fstat(descriptor)
        if (status.st_dev, status.st_ino) != identity:
            raise ReleaseTransactionError(
                "published release path changed during commit"
            )
        _assert_descriptor_matches_seal(
            descriptor,
            seal,
            maximum_bytes=maximum_bytes,
            expected_link_count=2,
            exact_times=False,
        )
    finally:
        os.close(descriptor)


def publish_release_pair(
    archive: FileSeal,
    checksum: FileSeal,
    *,
    archive_destination: Path,
    checksum_destination: Path,
    maximum_archive_bytes: int,
) -> None:
    archive_destination = archive_destination.absolute()
    checksum_destination = checksum_destination.absolute()
    if (
        archive_destination.parent != checksum_destination.parent
        or archive_destination.name != archive.path.name
        or checksum_destination.name != archive.path.name + ".sha256"
    ):
        raise ReleaseTransactionError(
            "release publication paths do not match the sealed archive"
        )
    for path in (
        archive.path,
        checksum.path,
        archive_destination,
        checksum_destination,
    ):
        normalized = Path(os.path.normpath(str(path.absolute())))
        if path.absolute() != normalized:
            raise ReleaseTransactionError(
                "release publication paths must be normalized"
            )
    assert_sealed(archive, maximum_bytes=maximum_archive_bytes)
    assert_sealed(checksum, maximum_bytes=4 * 1024)

    destination_parent = -1
    archive_parent = -1
    checksum_parent = -1
    archive_descriptor = -1
    checksum_descriptor = -1
    checksum_identity: tuple[int, int] | None = None
    archive_identity: tuple[int, int] | None = None
    try:
        destination_parent = _directory_descriptor(
            archive_destination.parent,
            private=False,
        )
        archive_parent = _directory_descriptor(
            archive.path.parent,
            private=True,
        )
        checksum_parent = _directory_descriptor(
            checksum.path.parent,
            private=True,
        )
        archive_descriptor = os.open(
            archive.path.name,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=archive_parent,
        )
        checksum_descriptor = os.open(
            checksum.path.name,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=checksum_parent,
        )
        if os.fstat(archive_descriptor).st_dev != os.fstat(
            destination_parent
        ).st_dev:
            raise ReleaseTransactionError(
                "release transaction and destination are on different filesystems"
            )
        expected_checksum = (
            f"{archive.sha256}  {archive.path.name}\n".encode("utf-8")
        )
        checksum_digest, checksum_size = _hash_descriptor(
            checksum_descriptor,
            maximum_bytes=4 * 1024,
        )
        if (
            checksum_size != len(expected_checksum)
            or checksum_digest
            != hashlib.sha256(expected_checksum).hexdigest()
        ):
            raise ReleaseTransactionError(
                "release checksum does not match the sealed archive"
            )
        for destination_name in (
            checksum_destination.name,
            archive_destination.name,
        ):
            try:
                os.stat(
                    destination_name,
                    dir_fd=destination_parent,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            raise ReleaseTransactionError(
                "release destination already exists"
            )
        checksum_identity = _publish_one_file(
            source_parent=checksum_parent,
            source_name=checksum.path.name,
            source_descriptor=checksum_descriptor,
            seal=checksum,
            destination_parent=destination_parent,
            destination_name=checksum_destination.name,
            maximum_bytes=4 * 1024,
        )
        archive_identity = _publish_one_file(
            source_parent=archive_parent,
            source_name=archive.path.name,
            source_descriptor=archive_descriptor,
            seal=archive,
            destination_parent=destination_parent,
            destination_name=archive_destination.name,
            maximum_bytes=maximum_archive_bytes,
        )
        _assert_public_destination(
            parent=destination_parent,
            name=checksum_destination.name,
            seal=checksum,
            identity=checksum_identity,
            maximum_bytes=4 * 1024,
        )
        _assert_public_destination(
            parent=destination_parent,
            name=archive_destination.name,
            seal=archive,
            identity=archive_identity,
            maximum_bytes=maximum_archive_bytes,
        )
        os.fsync(destination_parent)
    except FileExistsError as error:
        try:
            os.fsync(destination_parent)
        except OSError:
            pass
        raise ReleaseTransactionError(
            "release destination already exists"
        ) from error
    except BaseException:
        # Publication is monotonic. Once a path has been committed with
        # RENAME_EXCL it is never removed by a racy check-then-unlink rollback.
        # A later verifier/recovery pass must prove and adopt the exact inode
        # or stop for operator reconciliation.
        try:
            os.fsync(destination_parent)
        except OSError:
            pass
        raise
    finally:
        for descriptor in (
            archive_descriptor,
            checksum_descriptor,
            checksum_parent,
            archive_parent,
            destination_parent,
        ):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
