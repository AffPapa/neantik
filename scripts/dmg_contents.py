"""Compare mounted DMG app bytes with the qualified ZIP without extracting it."""
from __future__ import annotations

import hashlib
import os
import stat
import zipfile
from pathlib import Path, PurePosixPath


def digest_stream(stream) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def assert_volume_inventory(volume: Path) -> None:
    """Our UDZO source has exactly two root entries, including on the real .83 DMG."""
    if {path.name for path in volume.iterdir()} != {"NeAntik.app", "Applications"}:
        raise ValueError("DMG contains an unreviewed root payload")
    app, applications = volume / "NeAntik.app", volume / "Applications"
    if (not app.is_dir() or app.is_symlink() or not applications.is_symlink() or
            os.readlink(applications) != "/Applications"):
        raise ValueError("DMG root structure is invalid")


def assert_app_matches_zip(app: Path, archive: Path) -> None:
    """Include symlink targets and executable bits; ignore directory timestamps."""
    expected = {}
    total = 0
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if not entries or len(entries) > 200_000:
            raise ValueError("ZIP inventory is invalid")
        for entry in entries:
            name = PurePosixPath(entry.filename)
            if (name.is_absolute() or ".." in name.parts or
                    not name.parts or name.parts[0] != "NeAntik.app" or
                    "\\" in entry.filename or "\x00" in entry.filename):
                raise ValueError("ZIP path is unsafe")
            if entry.is_dir():
                continue
            relative = name.relative_to("NeAntik.app").as_posix()
            if relative in expected or relative == ".":
                raise ValueError("ZIP inventory contains duplicate paths")
            total += entry.file_size
            if total > 32 * 1024**3:
                raise ValueError("ZIP inventory exceeds its limit")
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                if entry.file_size > 4096:
                    raise ValueError("ZIP symlink exceeds its limit")
                expected[relative] = ("link", source.read(entry))
            elif stat.S_IFMT(mode) in (0, stat.S_IFREG):
                with source.open(entry) as stream:
                    expected[relative] = ("file", mode & 0o111, digest_stream(stream))
            else:
                raise ValueError("ZIP contains a special file")
    if not app.is_dir() or app.is_symlink():
        raise ValueError("Mounted app is invalid")
    observed = {}
    for root, directories, files in os.walk(app, followlinks=False):
        for name in tuple(directories) + tuple(files):
            path = Path(root) / name
            mode = path.lstat().st_mode
            relative = path.relative_to(app).as_posix()
            if stat.S_ISLNK(mode):
                observed[relative] = ("link", os.fsencode(os.readlink(path)))
                if name in directories:
                    directories.remove(name)
            elif stat.S_ISREG(mode):
                with path.open("rb") as stream:
                    observed[relative] = ("file", mode & 0o111, digest_stream(stream))
            elif not stat.S_ISDIR(mode):
                raise ValueError("Mounted app contains a special file")
    if not expected or observed != expected:
        raise ValueError("Mounted app differs from the qualified ZIP")
