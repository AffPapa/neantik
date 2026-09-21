#!/usr/bin/env python3
"""Run a privacy-safe OS-process/profile-isolation smoke harness.

The harness uses temporary directories and short-lived Python child processes;
it does not launch Chromium, inspect user profiles, read Keychain, or emit
paths, profile names, seeds, cookies, or credentials. Its minimized report is
validated by verify-profile-isolation-report.py and is evidence for the
filesystem/process harness only, not for a browser runtime.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import secrets
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def _bounded_count(raw: str) -> int:
    value = int(raw)
    if not 1 <= value <= 100:
        raise argparse.ArgumentTypeError("count must be between 1 and 100")
    return value


def run(count: int) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="neantik-profile-harness-") as root:
        root_path = Path(root)
        processes: list[tuple[subprocess.Popen[bytes], Path]] = []
        browser_data_directories: set[tuple[int, int]] = set()
        cookie_store_paths: set[tuple[int, int]] = set()
        lock_paths: set[tuple[int, int]] = set()
        identity_tokens: set[str] = set()

        try:
            for index in range(count):
                profile_root = root_path / f"profile-{index}"
                browser_data = profile_root / "BrowserData"
                browser_data.mkdir(parents=True)
                cookies = browser_data / "Cookies"
                cookies.write_bytes(b"harness-cookie-store-marker\n")
                lock_path = profile_root / "browser.lock"
                lock_path.touch()

                identity_tokens.add(hashlib.sha256(secrets.token_bytes(32)).hexdigest())
                browser_stat = browser_data.stat()
                cookie_stat = cookies.stat()
                lock_stat = lock_path.stat()
                browser_data_directories.add((browser_stat.st_dev, browser_stat.st_ino))
                cookie_store_paths.add((cookie_stat.st_dev, cookie_stat.st_ino))
                lock_paths.add((lock_stat.st_dev, lock_stat.st_ino))

                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        (
                            "import fcntl, sys, time\n"
                            "handle = open(sys.argv[1], 'r+')\n"
                            "fcntl.flock(handle.fileno(), fcntl.LOCK_EX)\n"
                            "print('READY', flush=True)\n"
                            "time.sleep(60)\n"
                        ),
                        str(lock_path),
                    ],
                    cwd=browser_data,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                processes.append((process, lock_path))
                if process.stdout is None or process.stdout.readline() != b"READY\n":
                    raise RuntimeError("harness child did not acquire its lock")
                if process.stdout is not None:
                    process.stdout.close()

            concurrent_launch_blocked = False
            probe_handle = (root_path / "profile-0" / "browser.lock").open("r+")
            try:
                try:
                    fcntl.flock(probe_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    concurrent_launch_blocked = True
            finally:
                probe_handle.close()

            for process, _ in processes:
                if process.poll() is not None:
                    raise RuntimeError("harness child exited before recovery check")

            for process, _ in processes:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
            for process, lock_path in processes:
                process.wait(timeout=5)
                with lock_path.open("r+") as recovery_handle:
                    fcntl.flock(recovery_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                lock_path.unlink()

            recovery_state = "clean" if all(
                not lock_path.exists() for _, lock_path in processes
            ) else "required"
            report = {
                "status": "partial",
                "profileCount": count,
                "distinctBrowserDataDirectories": len(browser_data_directories),
                "distinctIdentitySeeds": len(identity_tokens),
                "sharedCookieStores": count - len(cookie_store_paths),
                "sharedLockFiles": count - len(lock_paths),
                "concurrentLaunchBlocked": concurrent_launch_blocked,
                "recoveryState": recovery_state,
                "generatedAt": _utc_now(),
            }
            if recovery_state != "clean" or not concurrent_launch_blocked:
                report["status"] = "failed"
            return report
        finally:
            for process, _ in processes:
                if process.poll() is None:
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=_bounded_count, default=3)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        report = run(args.count)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"profile isolation harness failed: {error}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            report,
            ensure_ascii=False,
            separators=(",", ":") if args.json else None,
            indent=None if args.json else 2,
        )
    )
    return 0 if report["status"] in {"verified", "partial"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
