#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import stat
import subprocess
import sys
from pathlib import Path
from typing import BinaryIO


def exact_executable(path: str) -> str:
    candidate = Path(path)
    if not candidate.is_absolute():
        raise ValueError("command executable must be absolute")
    try:
        metadata = os.lstat(candidate)
    except OSError as error:
        raise ValueError("command executable is unavailable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid not in {0, os.geteuid()}
        or not os.access(candidate, os.X_OK)
    ):
        raise ValueError("command executable must be a regular executable")
    return str(candidate)


def open_private_log(path: Path) -> BinaryIO:
    if not path.is_absolute():
        raise ValueError("log path must be absolute")
    descriptor = os.open(
        path,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            raise ValueError("log output is unsafe")
        os.fchmod(descriptor, 0o600)
        return os.fdopen(descriptor, "wb", buffering=0)
    except Exception:
        os.close(descriptor)
        raise


def run_exact_command(
    command: list[str],
    timeout: float,
    *,
    output: BinaryIO | None = None,
) -> int:
    if not command or timeout <= 0 or timeout > 600:
        raise ValueError("invalid exact command timeout request")
    command = [exact_executable(command[0]), *command[1:]]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT if output is not None else None,
        shell=False,
        close_fds=True,
    )
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        return 124


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run one exact executable without a shell and preserve its "
            "exit status, with a bounded timeout."
        )
    )
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    log: BinaryIO | None = None
    try:
        if args.log is not None:
            log = open_private_log(args.log)
        return run_exact_command(
            command,
            args.timeout,
            output=log,
        )
    except (OSError, ValueError):
        print("Exact command runner rejected the request.", file=sys.stderr)
        return 64
    finally:
        if log is not None:
            log.close()


if __name__ == "__main__":
    raise SystemExit(main())
