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
        self.assertIn(
            '"$PROJECT_DIR/scripts/verify-direct-update-policy.py"',
            text,
        )
        self.assertIn(
            '"$PROJECT_DIR/scripts/verify-public-fingerprint-corpus.py"',
            text,
        )
        self.assertIn(
            '"$PROJECT_DIR/scripts/verify-runtime-source-provenance.py"',
            text,
        )
        self.assertIn(
            '"$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py"',
            text,
        )
        self.assertIn('CANDIDATE_LOCK="$4"', text)
        self.assertIn('--lock "$CANDIDATE_LOCK"', text)
        self.assertIn('--source-root "$SOURCE_ROOT"', text)
        self.assertIn(
            "NEANTIK_GUI_FINGERPRINT_REPORT:?",
            text,
            "Direct release must require real GUI fingerprint evidence",
        )
        self.assertIn(
            '"$PROJECT_DIR/scripts/verify-gui-fingerprint-report.py"',
            text,
        )
        self.assertIn(
            '--integrated-app "$APP_PATH"',
            text,
            "GUI evidence must be bound to the exact packaged app",
        )
        self.assertLess(
            text.index('"$PROJECT_DIR/scripts/verify-gui-fingerprint-report.py"'),
            text.index('ditto --norsrc -c -k --keepParent "$APP_PATH"'),
            "GUI evidence must pass before archive creation and notarization",
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
