import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "scripts" / "package-integrated-app.sh"


class PackageIntegratedAppScriptTests(unittest.TestCase):
    def test_public_release_gate_runs_on_public_bundle_name(self) -> None:
        text = PACKAGER.read_text(encoding="utf-8")

        self.assertIn(
            ".neantik-integrated-verification.XXXXXX",
            text,
        )
        self.assertIn('PUBLIC_VERIFY_APP="$PUBLIC_VERIFY_ROOT/NeAntik.app"', text)
        self.assertIn(
            'verify-integrated-release.sh" "$PUBLIC_VERIFY_APP"',
            text,
        )
        self.assertNotIn(
            'verify-integrated-release.sh" "$OUTPUT_APP"',
            text,
        )

    def test_engineering_bundle_is_restored_even_on_interruption(self) -> None:
        text = PACKAGER.read_text(encoding="utf-8")
        move_to_public = text.index('mv "$OUTPUT_APP" "$PUBLIC_VERIFY_APP"')
        verify = text.index(
            'verify-integrated-release.sh" "$PUBLIC_VERIFY_APP"'
        )
        move_back = text.index('mv "$PUBLIC_VERIFY_APP" "$OUTPUT_APP"', verify)

        self.assertLess(move_to_public, verify)
        self.assertLess(verify, move_back)
        self.assertIn("restore_engineering_bundle", text)
        self.assertIn("trap cleanup EXIT", text)


if __name__ == "__main__":
    unittest.main()
