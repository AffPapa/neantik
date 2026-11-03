#!/usr/bin/env python3
"""Give every regular file in a staged runtime its own inode."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import tempfile
from pathlib import Path


def materialize(root: Path) -> int:
    if root.is_symlink():
        raise ValueError("runtime root must not be a symlink")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("runtime root must be a real directory")

    changed = 0
    for directory, names, files in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in files:
            path = base / name
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink <= 1:
                continue

            fd, temporary_name = tempfile.mkstemp(prefix=".neantik-materialize-", dir=base)
            os.close(fd)
            temporary = Path(temporary_name)
            try:
                shutil.copyfile(path, temporary, follow_symlinks=False)
                shutil.copystat(path, temporary, follow_symlinks=False)
                if hasattr(os, "listxattr"):
                    for attribute in os.listxattr(path, follow_symlinks=False):
                        os.setxattr(
                            temporary,
                            attribute,
                            os.getxattr(path, attribute, follow_symlinks=False),
                            follow_symlinks=False,
                        )
                os.replace(temporary, path)
            finally:
                try:
                    temporary.unlink()
                except FileNotFoundError:
                    pass

            result = path.lstat()
            if not stat.S_ISREG(result.st_mode) or result.st_nlink != 1:
                raise OSError(f"could not isolate staged runtime file: {path}")
            changed += 1
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args()
    try:
        count = materialize(args.runtime)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"materialized linked runtime files: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
