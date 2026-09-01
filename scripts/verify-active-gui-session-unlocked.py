#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import subprocess
import sys


class ActiveSessionError(RuntimeError):
    pass


def parse_active_session_unlocked(ioreg_output: str, *, user_id: int) -> None:
    sessions = re.findall(r"\{[^{}]*\}", ioreg_output)
    current: str | None = None
    for session in sessions:
        identifier = re.search(r'"?kCGSSessionUserIDKey"?=(\d+)', session)
        if (
            identifier is not None
            and int(identifier.group(1)) == user_id
            and re.search(r'"?kCGSSessionOnConsoleKey"?=Yes', session)
            and re.search(r'"?kCGSessionLoginDoneKey"?=Yes', session)
        ):
            current = session
            break
    if current is None:
        raise ActiveSessionError(
            "the active signed-in macOS GUI session could not be identified"
        )
    state = re.search(r'"?CGSSessionScreenIsLocked"?=(Yes|No)', current)
    # macOS may omit the lock key for an unlocked console session. A present
    # affirmative value is authoritative; the active-console and login-done
    # markers above keep an absent value from accepting a background session.
    if state is not None and state.group(1) == "Yes":
        raise ActiveSessionError(
            "the macOS GUI session is locked; unlock it before Direct release"
        )


def verify_active_session_unlocked() -> None:
    user_id = os.geteuid()
    try:
        console_owner = os.stat("/dev/console", follow_symlinks=False).st_uid
    except OSError as error:
        raise ActiveSessionError("the macOS console session is unavailable") from error
    if console_owner != user_id:
        raise ActiveSessionError(
            "run Direct release from the signed-in user's Terminal session"
        )
    launchctl = subprocess.run(
        ["/bin/launchctl", "print", f"gui/{user_id}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=10,
    )
    if launchctl.returncode != 0:
        raise ActiveSessionError("the signed-in macOS GUI session is unavailable")
    ioreg = subprocess.run(
        ["/usr/sbin/ioreg", "-n", "Root", "-d1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
        text=True,
    )
    if ioreg.returncode != 0:
        raise ActiveSessionError("the macOS screen-lock state could not be inspected")
    parse_active_session_unlocked(ioreg.stdout, user_id=user_id)


def main() -> int:
    try:
        verify_active_session_unlocked()
    except ActiveSessionError as error:
        print(f"Direct release session check failed: {error}", file=sys.stderr)
        return 69
    print("PASS: active macOS GUI session is unlocked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
