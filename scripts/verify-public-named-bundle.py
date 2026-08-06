#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path


class PublicNameVerificationError(RuntimeError):
    pass


class VerificationInterrupted(RuntimeError):
    def __init__(self, signum: int) -> None:
        super().__init__(f"Public-name verification interrupted by signal {signum}")
        self.signum = signum


def path_exists(path: Path) -> bool:
    return os.path.lexists(path)


def validate_inputs(engineering_app: Path, verifier: Path) -> None:
    if not engineering_app.is_absolute():
        raise PublicNameVerificationError(
            "Engineering bundle path must be absolute"
        )
    if (
        not engineering_app.is_dir()
        or engineering_app.is_symlink()
        or engineering_app.name == "NeAntik.app"
    ):
        raise PublicNameVerificationError(
            "Engineering bundle must be a regular non-public .app directory"
        )

    parent = engineering_app.parent
    if (
        not parent.is_dir()
        or parent.is_symlink()
        or parent.stat().st_uid != os.geteuid()
    ):
        raise PublicNameVerificationError(
            "Engineering bundle parent is not a safe owned directory"
        )

    if (
        not verifier.is_absolute()
        or not verifier.is_file()
        or verifier.is_symlink()
        or not os.access(verifier, os.X_OK)
    ):
        raise PublicNameVerificationError(
            "Public bundle verifier must be an executable regular file"
        )


def run_verifier(verifier: Path, staged_app: Path) -> int:
    process: subprocess.Popen[bytes] | None = None

    def interrupt(signum: int, _frame: object) -> None:
        raise VerificationInterrupted(signum)

    previous_handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    try:
        process = subprocess.Popen(
            [str(verifier), str(staged_app)],
            start_new_session=True,
        )
        return process.wait()
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def verify_public_named_bundle(engineering_app: Path, verifier: Path) -> int:
    validate_inputs(engineering_app, verifier)

    staging_root = Path(
        tempfile.mkdtemp(
            prefix=".neantik-public-name-verification.",
            dir=engineering_app.parent,
        )
    )
    os.chmod(staging_root, 0o700)
    staged_app = staging_root / "NeAntik.app"
    moved = False
    restore_error: PublicNameVerificationError | None = None
    verifier_status = 1

    try:
        os.replace(engineering_app, staged_app)
        moved = True
        verifier_status = run_verifier(verifier, staged_app)
    finally:
        if moved and path_exists(staged_app):
            if path_exists(engineering_app):
                restore_error = PublicNameVerificationError(
                    "Engineering output reappeared during verification; "
                    f"the verified bundle is preserved at {staged_app}"
                )
            else:
                os.replace(staged_app, engineering_app)
                moved = False

        if not moved:
            try:
                staging_root.rmdir()
            except FileNotFoundError:
                pass

        if restore_error is not None:
            raise restore_error

    return verifier_status


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Atomically verify an internal engineering app under the strict "
            "public NeAntik.app bundle name, then restore it."
        )
    )
    parser.add_argument("--engineering-app", type=Path, required=True)
    parser.add_argument("--verifier", type=Path, required=True)
    args = parser.parse_args()

    try:
        return verify_public_named_bundle(
            args.engineering_app,
            args.verifier,
        )
    except VerificationInterrupted as error:
        print(str(error), file=sys.stderr)
        return 128 + error.signum
    except (OSError, PublicNameVerificationError) as error:
        print(f"Public-name bundle verification failed: {error}", file=sys.stderr)
        return 70


if __name__ == "__main__":
    sys.exit(main())
