#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import runpy
import shutil
import stat
import sys
import tempfile
import platform
from pathlib import Path


SYSTEM_GIT = "/usr/bin/git"


def fail(message: str) -> int:
    print(f"Isolated release Python failed: {message}", file=sys.stderr)
    return 65


def belongs_to_git_worktree(project_root: Path) -> bool:
    if (project_root / ".git").exists():
        return True
    try:
        inside = subprocess.run(
            [
                SYSTEM_GIT,
                "-C",
                str(project_root),
                "rev-parse",
                "--is-inside-work-tree",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
        if inside.returncode != 0 or inside.stdout.strip() != "true":
            return False
        root = subprocess.run(
            [
                SYSTEM_GIT,
                "-C",
                str(project_root),
                "rev-parse",
                "--show-toplevel",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
        if root.returncode != 0:
            return False
        git_root = Path(root.stdout.strip()).resolve()
        project_root.resolve().relative_to(git_root)
        return True
    except (OSError, subprocess.SubprocessError, ValueError):
        return False


def main() -> int:
    if sys.version_info < (3, 11):
        return fail("Python 3.11 or newer is required")
    if platform.machine() != "arm64":
        return fail("an ARM64 Python interpreter is required")
    if not sys.flags.isolated or not sys.dont_write_bytecode:
        return fail("the release runner requires Python -I -B")
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
        or not belongs_to_git_worktree(project_root)
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
    # Keep only the interpreter-owned standard library.  In particular, do
    # not let Homebrew/user site-packages or the caller's working directory
    # shadow stdlib modules during a release.  The reviewed repository
    # scripts remain importable, but only after the stdlib entries.
    standard_library = [
        entry
        for entry in sys.path
        if entry
        and "site-packages" not in Path(entry).parts
        and "dist-packages" not in Path(entry).parts
    ]
    sys.path[:] = [*standard_library, str(scripts_root)]
    arguments = sys.argv[2:]
    sys.argv = [str(target), *arguments]
    try:
        runpy.run_path(str(target), run_name="__main__")
    finally:
        shutil.rmtree(cache_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
