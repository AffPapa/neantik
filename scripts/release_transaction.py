#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import ctypes
import errno
import os
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
        or before.st_nlink != 1
        or after.st_nlink != 1
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
        if _identity(before) != expected or before.st_nlink != 1:
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
            events
            or _identity(before) != _identity(after)
            or after.st_nlink != 1
            or path_status.st_dev != seal.device
            or path_status.st_ino != seal.inode
            or digest != seal.sha256
            or total != seal.size
        ):
            raise ReleaseTransactionError(
                "sealed release file changed during the external phase"
            ) from action_error
        if action_error is not None:
            raise action_error
        return result  # type: ignore[return-value]
    except OSError as error:
        raise ReleaseTransactionError(
            "sealed release phase could not be observed"
        ) from error
    finally:
        if queue is not None:
            queue.close()
        os.close(descriptor)


def write_checksum_sidecar(
    archive: FileSeal,
    destination: Path,
) -> FileSeal:
    destination = destination.absolute()
    parent = _directory_descriptor(destination.parent, private=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    payload = (
        f"{archive.sha256}  {archive.path.name}\n".encode("utf-8")
    )
    try:
        output = os.open(
            destination.name,
            flags,
            0o600,
            dir_fd=parent,
        )
    except OSError as error:
        os.close(parent)
        raise ReleaseTransactionError(
            "release checksum output is unavailable"
        ) from error
    try:
        created_identity = os.fstat(output)
    except OSError as error:
        os.close(output)
        os.close(parent)
        raise ReleaseTransactionError(
            "release checksum output is unavailable"
        ) from error
    succeeded = False
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
        os.fsync(parent)
        succeeded = True
    except OSError as error:
        raise ReleaseTransactionError(
            "release checksum write failed"
        ) from error
    finally:
        os.close(output)
        if not succeeded:
            try:
                current = os.stat(
                    destination.name,
                    dir_fd=parent,
                    follow_symlinks=False,
                )
                if (
                    current.st_dev == created_identity.st_dev
                    and current.st_ino == created_identity.st_ino
                ):
                    os.unlink(destination.name, dir_fd=parent)
            except (FileNotFoundError, OSError):
                pass
        os.close(parent)
    return seal_regular_file(
        destination,
        maximum_bytes=4 * 1024,
    )


def _unlink_if_identity(
    parent: int,
    name: str,
    identity: tuple[int, int],
) -> None:
    try:
        status = os.stat(
            name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        if (status.st_dev, status.st_ino) == identity:
            os.unlink(name, dir_fd=parent)
    except (FileNotFoundError, OSError):
        return


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
    hidden_name = (
        f".{destination_name}.neantik-publish-{uuid.uuid4().hex}"
    )
    hidden_identity: tuple[int, int] | None = None
    validated_hidden_identity: tuple[int, int] | None = None
    final_identity: tuple[int, int] | None = None
    try:
        os.link(
            source_name,
            hidden_name,
            src_dir_fd=source_parent,
            dst_dir_fd=destination_parent,
            follow_symlinks=False,
        )
        hidden_descriptor = os.open(
            hidden_name,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=destination_parent,
        )
        try:
            hidden_status = os.fstat(hidden_descriptor)
            hidden_identity = (
                hidden_status.st_dev,
                hidden_status.st_ino,
            )
            validated_hidden_identity = hidden_identity
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
            destination_parent,
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
        hidden_identity = None
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
        if hidden_identity is not None:
            _unlink_if_identity(
                destination_parent,
                hidden_name,
                hidden_identity,
            )
        if validated_hidden_identity is not None:
            _unlink_if_identity(
                destination_parent,
                hidden_name,
                validated_hidden_identity,
            )
        if final_identity is not None:
            _unlink_if_identity(
                destination_parent,
                destination_name,
                final_identity,
            )
        try:
            os.fsync(destination_parent)
        except OSError:
            pass
        raise


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
        if archive_identity is not None and destination_parent >= 0:
            _unlink_if_identity(
                destination_parent,
                archive_destination.name,
                archive_identity,
            )
        if checksum_identity is not None:
            _unlink_if_identity(
                destination_parent,
                checksum_destination.name,
                checksum_identity,
            )
        try:
            os.fsync(destination_parent)
        except OSError:
            pass
        raise ReleaseTransactionError(
            "release destination already exists"
        ) from error
    except BaseException:
        if archive_identity is not None and destination_parent >= 0:
            _unlink_if_identity(
                destination_parent,
                archive_destination.name,
                archive_identity,
            )
        if checksum_identity is not None:
            _unlink_if_identity(
                destination_parent,
                checksum_destination.name,
                checksum_identity,
            )
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
