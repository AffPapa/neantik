#!/usr/bin/env python3
from __future__ import annotations

import os
import runpy
import shutil
import stat
import sys
import tempfile
import platform
from pathlib import Path


def fail(message: str) -> int:
    print(f"Isolated release Python failed: {message}", file=sys.stderr)
    return 65


def main() -> int:
    if sys.version_info < (3, 11):
        return fail("Python 3.11 or newer is required")
    if platform.machine() != "arm64":
        return fail("an ARM64 Python interpreter is required")
    if len(sys.argv) < 2:
        return fail("a release script path is required")
    raw_target = Path(sys.argv[1])
    target = raw_target.absolute()
    if target != raw_target or ".." in raw_target.parts:
        return fail("the release script path must be normalized")
    scripts_root = target.parent
    project_root = scripts_root.parent
    if (
        scripts_root.name != "scripts"
        or scripts_root.is_symlink()
        or project_root.is_symlink()
        or not (project_root / ".git").exists()
    ):
        return fail("the release script must belong to a Git worktree")
    try:
        status = target.lstat()
    except OSError:
        return fail("the release script is unavailable")
    if (
        target.is_symlink()
        or not stat.S_ISREG(status.st_mode)
        or status.st_uid != os.geteuid()
        or status.st_nlink != 1
        or status.st_mode & 0o022
    ):
        return fail("the release script is unsafe")
    dist = project_root / "dist"
    try:
        dist_status = dist.lstat()
    except OSError:
        return fail("the release dist directory is unavailable")
    if (
        dist.is_symlink()
        or not stat.S_ISDIR(dist_status.st_mode)
        or dist_status.st_uid != os.geteuid()
        or dist_status.st_mode & 0o022
    ):
        return fail("the release dist directory is unsafe")

    cache_root = Path(
        tempfile.mkdtemp(prefix=".neantik-python.", dir=dist)
    )
    cache_root.chmod(0o700)
    for key in tuple(os.environ):
        if key.startswith("PYTHON"):
            os.environ.pop(key)
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    os.environ["PYTHONNOUSERSITE"] = "1"
    os.environ["PYTHONPYCACHEPREFIX"] = str(cache_root)
    sys.pycache_prefix = str(cache_root)
    sys.path[:] = [str(scripts_root), *sys.path]
    arguments = sys.argv[2:]
    sys.argv = [str(target), *arguments]
    try:
        runpy.run_path(str(target), run_name="__main__")
    finally:
        shutil.rmtree(cache_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
