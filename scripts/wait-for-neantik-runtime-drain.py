#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time


def candidate_process_count(app: Path, process_table: str, uid: int) -> int:
    supplied_app = app.absolute()
    resolved_app = app.resolve(strict=True)
    app_paths = {supplied_app, resolved_app}
    managers = {
        str(candidate / "Contents" / "MacOS" / "NeAntik")
        for candidate in app_paths
    }
    runtime_roots = {
        str(
            candidate
            / "Contents"
            / "Resources"
            / "NeAntik Browser.app"
        ) + "/"
        for candidate in app_paths
    }
    count = 0
    for raw_line in process_table.splitlines():
        fields = raw_line.strip().split(maxsplit=2)
        if len(fields) != 3:
            continue
        raw_uid, _raw_pid, command = fields
        try:
            process_uid = int(raw_uid)
        except ValueError:
            continue
        if process_uid != uid:
            continue
        if any(
            command == manager or command.startswith(manager + " ")
            for manager in managers
        ):
            count += 1
        elif any(
            command.startswith(runtime_root)
            for runtime_root in runtime_roots
        ):
            count += 1
    return count


def read_process_table() -> str:
    result = subprocess.run(
        ["/bin/ps", "-axww", "-o", "uid=,pid=,command="],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError("process inventory is unavailable")
    return result.stdout


def wait_for_drain(
    app: Path,
    timeout: float,
    poll_interval: float,
    clean_observations: int,
) -> bool:
    deadline = time.monotonic() + timeout
    clean_count = 0
    while time.monotonic() <= deadline:
        try:
            count = candidate_process_count(
                app,
                read_process_table(),
                os.getuid(),
            )
        except (OSError, RuntimeError, subprocess.SubprocessError):
            clean_count = 0
        else:
            if count == 0:
                clean_count += 1
                if clean_count >= clean_observations:
                    return True
            else:
                clean_count = 0
        time.sleep(poll_interval)
    return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Wait until processes from one exact NeAntik.app candidate exit."
        )
    )
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=45)
    parser.add_argument("--poll-interval", type=float, default=0.5)
    parser.add_argument("--clean-observations", type=int, default=2)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if (
        args.timeout <= 0
        or args.poll_interval <= 0
        or args.clean_observations < 2
    ):
        print("Invalid runtime drain policy.", file=sys.stderr)
        return 64
    if not args.app.is_dir() or args.app.name != "NeAntik.app":
        print("Exact NeAntik.app candidate is unavailable.", file=sys.stderr)
        return 66
    try:
        drained = wait_for_drain(
            args.app,
            timeout=args.timeout,
            poll_interval=args.poll_interval,
            clean_observations=args.clean_observations,
        )
    except OSError:
        drained = False
    if not drained:
        print(
            "Exact NeAntik candidate processes did not finish safely.",
            file=sys.stderr,
        )
        return 67
    print("PASS: exact NeAntik candidate processes are drained.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
