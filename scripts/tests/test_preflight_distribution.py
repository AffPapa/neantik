import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "preflight-distribution.sh"


class DistributionPreflightTests(unittest.TestCase):
    def run_preflight(
        self,
        *,
        selected_identity: str,
        mode: str = "direct",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            security = root / "security"
            security.write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    if [ "$1" = "find-identity" ]; then
                      printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Test (TEAMID)"'
                      exit 0
                    fi
                    exit 1
                    """
                ),
                encoding="utf-8",
            )
            security.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{root}:{environment['PATH']}"
            environment["NEANTIK_SIGNING_IDENTITY"] = selected_identity
            environment["NEANTIK_NOTARY_PROFILE"] = "test-keychain-profile"
            return subprocess.run(
                [str(SCRIPT), mode],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

    def test_direct_identity_and_keychain_profile_pass(self) -> None:
        result = self.run_preflight(
            selected_identity="Developer ID Application: Test (TEAMID)"
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "PASS    Developer ID Application identity is installed",
            result.stdout,
        )
        self.assertIn(
            "PASS    NEANTIK_SIGNING_IDENTITY resolves",
            result.stdout,
        )
        self.assertIn("Distribution preflight passed.", result.stdout)

    def test_wrong_identity_fails_closed(self) -> None:
        result = self.run_preflight(
            selected_identity="Apple Development: Test (TEAMID)"
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("does not resolve to Developer ID Application", result.stdout)

    def test_store_mode_is_not_part_of_open_source_distribution(self) -> None:
        result = self.run_preflight(
            selected_identity="Developer ID Application: Test (TEAMID)",
            mode="store",
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("Direct Distribution only", result.stderr)


if __name__ == "__main__":
    unittest.main()
