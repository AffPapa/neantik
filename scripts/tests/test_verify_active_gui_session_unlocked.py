from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-active-gui-session-unlocked.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_active_gui_session_unlocked", SCRIPT
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture(*, user_id: int, locked: str) -> str:
    return (
        '    "IOConsoleUsers" = ({'
        '"kCGSSessionOnConsoleKey"=Yes,'
        '"kCGSessionLoginDoneKey"=Yes,'
        f'"kCGSSessionUserIDKey"={user_id},'
        f'"CGSSessionScreenIsLocked"={locked}'
        '})\n'
    )


class ActiveGUISessionTests(unittest.TestCase):
    def test_accepts_current_unlocked_console_session(self) -> None:
        MODULE.parse_active_session_unlocked(
            fixture(user_id=502, locked="No"),
            user_id=502,
        )

    def test_rejects_locked_console_session(self) -> None:
        with self.assertRaisesRegex(MODULE.ActiveSessionError, "is locked"):
            MODULE.parse_active_session_unlocked(
                fixture(user_id=502, locked="Yes"),
                user_id=502,
            )

    def test_rejects_a_different_or_unknown_console_session(self) -> None:
        with self.assertRaisesRegex(
            MODULE.ActiveSessionError,
            "could not be identified",
        ):
            MODULE.parse_active_session_unlocked(
                fixture(user_id=501, locked="No"),
                user_id=502,
            )

    def test_accepts_the_unlocked_macos_form_that_omits_lock_state(self) -> None:
        data = fixture(user_id=502, locked="No").replace(
            '"CGSSessionScreenIsLocked"=No',
            '"SomeOtherState"=No',
        )
        MODULE.parse_active_session_unlocked(data, user_id=502)


if __name__ == "__main__":
    unittest.main()
