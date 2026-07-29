import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "release-direct.sh"


class ReleaseDirectScriptTests(unittest.TestCase):
    def test_public_release_builds_clean_non_overwriting_candidate(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?",
            text,
            "public Direct release must require the final hosted download URL",
        )
        self.assertIn(
            '"$PROJECT_DIR/scripts/verify-direct-notarized-archive.py"',
            text,
            "public Direct release must verify the final notarized ZIP",
        )
        self.assertIn('"$PROJECT_DIR/scripts/verify-direct-version-bump.py"', text)
        self.assertIn(
            '"$PROJECT_DIR/scripts/verify-direct-telemetry-disabled.py"',
            text,
        )
        self.assertIn('APP_PATH="$PROJECT_DIR/dist/NeAntik.app"', text)
        self.assertIn('ditto "$ENGINEERING_APP_PATH" "$APP_PATH"', text)
        self.assertNotIn('rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"', text)
        self.assertIn('shasum -a 256 "$(basename "$ARCHIVE_PATH")"', text)
        self.assertLess(
            text.index('"$PROJECT_DIR/scripts/verify-direct-notarized-archive.py"'),
            text.index("echo \"$ARCHIVE_PATH\""),
        )


if __name__ == "__main__":
    unittest.main()
