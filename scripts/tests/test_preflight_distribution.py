import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "preflight-distribution.sh"


class DistributionPreflightTests(unittest.TestCase):
    def run_store_preflight(self, installer_common_name: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            security = root / "security"
            security.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/sh
                    if [ "$1" = "find-identity" ] && [ "$4" = "codesigning" ]; then
                      printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Test (TEAMID)"'
                      exit 0
                    fi
                    if [ "$1" = "find-identity" ]; then
                      printf '%s\\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Test (TEAMID)"'
                      printf '%s\\n' '  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "{installer_common_name}"'
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
            environment["NEANTIK_STORE_INSTALLER_IDENTITY"] = installer_common_name
            return subprocess.run(
                [str(SCRIPT), "store"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

    def test_installer_identity_is_read_without_codesigning_filter(self) -> None:
        result = self.run_store_preflight(
            "Mac Installer Distribution: Test (TEAMID)"
        )
        self.assertIn(
            "PASS    Mac App Store installer identity is installed",
            result.stdout,
        )
        self.assertIn(
            "PASS    NEANTIK_STORE_INSTALLER_IDENTITY resolves",
            result.stdout,
        )

    def test_legacy_installer_common_name_is_accepted(self) -> None:
        result = self.run_store_preflight(
            "3rd Party Mac Developer Installer: Test (TEAMID)"
        )
        self.assertIn(
            "PASS    NEANTIK_STORE_INSTALLER_IDENTITY resolves",
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
