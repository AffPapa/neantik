#!/usr/bin/env python3
"""Coordinate cooperating build commands sharing one physical cache root."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import math
import os
import signal
from pathlib import Path
import stat
import subprocess
import sys
import time

ENV = "NEANTIK_NATIVE_CACHE_LOCK"


class CacheBusy(RuntimeError):
    pass


def inherited_fd(root):
    try:
        value = json.loads(os.environ.get(ENV, "null"))
        if not isinstance(value, dict) or value.get("root") != str(root):
            return None
        fd = value["fd"]
        if type(fd) is not int or fd < 3:
            return None
        actual = os.fstat(fd)
        expected = (root / ".native-build.lock").stat()
        if (stat.S_ISREG(actual.st_mode) and actual.st_uid == os.getuid() and actual.st_nlink == 1
                and (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino)):
            # The inherited open-file-description can reassert its flock.
            # An independently opened descriptor must compete for the lock.
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def supervise(command, *, env, pass_fds=(), stdout=None, stderr=None, cwd=None, timeout=None):
    """Cancel only this child group; settle it before releasing a cache lease."""
    if timeout is not None and (isinstance(timeout, bool) or not isinstance(timeout, (int, float))
                                or not math.isfinite(timeout) or timeout <= 0):
        raise ValueError("Timeout must be positive and finite")
    cancelled = []
    process = None
    deadline = time.monotonic() + timeout if timeout is not None else None
    timed_out = False

    def forward(signum, _frame):
        if not cancelled:
            cancelled.append((signum, time.monotonic()))
        if process is not None:
            try: os.killpg(process.pid, signum)
            except ProcessLookupError: pass

    previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        # Install cancellation before Popen: the new child can run immediately
        # and publish readiness before its parent has installed handlers.
        if cancelled:
            signum, _ = cancelled[0]
            return 128 + signum
        process = subprocess.Popen(command, env=env, pass_fds=pass_fds, stdout=stdout, stderr=stderr,
                                   cwd=cwd, start_new_session=True)
        # If cancellation arrived while Popen was returning, forward it now;
        # the handler could not signal the child before process was assigned.
        if cancelled:
            forward(cancelled[0][0], None)
        while True:
            if cancelled:
                signum, started = cancelled[0]
                process.poll()  # Reap the direct child before checking descendants.
                try: os.killpg(process.pid, 0)
                except ProcessLookupError:
                    process.wait()
                    return 124 if timed_out else 128 + signum
                if time.monotonic() - started >= 5:
                    try: os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    process.wait()
                    return 124 if timed_out else 128 + signum
            elif process.poll() is not None:
                return process.returncode
            elif deadline is not None and time.monotonic() >= deadline:
                timed_out = True
                forward(signal.SIGTERM, None)
            time.sleep(0.05)
    finally:
        for sig, handler in previous.items(): signal.signal(sig, handler)


@contextmanager
def cache_lock(cache):
    root = Path(cache).resolve()
    root.mkdir(parents=True, exist_ok=True)
    borrowed = inherited_fd(root)
    if borrowed is not None:
        yield borrowed
        return
    fd = os.open(root / ".native-build.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        identity = os.fstat(fd)
        if not stat.S_ISREG(identity.st_mode) or identity.st_uid != os.getuid() or identity.st_nlink != 1:
            raise ValueError("Build lock is not an owned regular file")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise CacheBusy("Another build/test command owns this cache; use its receipt before retrying.") from error
        yield fd
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--is-held", action="store_true")
    parser.add_argument("--timeout", type=float, help="Optional child deadline; default has no time limit")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.is_held:
        return 0 if inherited_fd(args.root.resolve()) is not None else 1
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provide a child command after --")
    try:
        with cache_lock(args.root) as fd:
            env = os.environ.copy()
            env[ENV] = json.dumps({"root": str(args.root.resolve()), "fd": fd})
            return supervise(command, env=env, pass_fds=(fd,), timeout=args.timeout)
    except CacheBusy as error:
        print(str(error), file=sys.stderr)
        return 75


if __name__ == "__main__":
    raise SystemExit(main())
