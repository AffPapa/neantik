import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SIGN_RUNTIME = ROOT / "scripts" / "sign-runtime.sh"


class SignRuntimeScriptTests(unittest.TestCase):
    def test_apple_strip_optimizer_runs_before_both_signing_paths(self) -> None:
        text = SIGN_RUNTIME.read_text(encoding="utf-8")
        manual = text.split("manual_public_alpha_sign() {", 1)[1].split(
            "\n}\n\nif [[ ! -d", 1
        )[0]
        packaging = text.split(
            'STAGED_APP="$STAGING/NeAntik Browser.app"',
            1,
        )[1]

        self.assertIn('remove_attached_signatures "$OUTPUT_APP"', manual)
        self.assertIn('optimize_runtime_size "$OUTPUT_APP"', manual)
        self.assertLess(
            manual.index('optimize_runtime_size "$OUTPUT_APP"'),
            manual.index('sign_code "$OUTPUT_APP"'),
        )
        self.assertIn('remove_attached_signatures "$STAGED_APP"', packaging)
        self.assertIn('optimize_runtime_size "$STAGED_APP"', packaging)
        self.assertLess(
            packaging.index('optimize_runtime_size "$STAGED_APP"'),
            packaging.index("sign_chrome.py"),
        )
        self.assertIn("optimize-runtime-size.py", text)
        self.assertIn("xcrun --find strip", text)

    def test_manual_signing_orders_nested_bundles_inside_out(self) -> None:
        text = SIGN_RUNTIME.read_text(encoding="utf-8")
        manual = text.split("manual_public_alpha_sign() {", 1)[1].split(
            "\n}\n\nif [[ ! -d", 1
        )[0]

        self.assertIn('*/Contents/MacOS/*|*/"NeAntik Browser Framework")', manual)
        self.assertLess(
            manual.index("sign_code \"$candidate\""),
            manual.index("sign_code \"$nested_app\""),
        )
        self.assertLess(
            manual.index("sign_code \"$nested_app\""),
            manual.index("sign_code \"$framework\""),
        )
        self.assertLess(
            manual.index("sign_code \"$framework\""),
            manual.index('sign_code "$OUTPUT_APP"'),
        )

    def test_public_icon_is_applied_before_both_signing_paths(self) -> None:
        text = SIGN_RUNTIME.read_text(encoding="utf-8")
        manual = text.split("manual_public_alpha_sign() {", 1)[1].split(
            "\n}\n\nif [[ ! -d", 1
        )[0]
        packaging = text.split(
            'STAGED_APP="$STAGING/NeAntik Browser.app"',
            1,
        )[1]

        self.assertIn('apply_public_runtime_icon "$OUTPUT_APP"', manual)
        self.assertLess(
            manual.index('apply_public_runtime_icon "$OUTPUT_APP"'),
            manual.index('sign_code "$OUTPUT_APP"'),
        )
        self.assertIn('apply_public_runtime_icon "$STAGED_APP"', packaging)
        self.assertLess(
            packaging.index('apply_public_runtime_icon "$STAGED_APP"'),
            packaging.index("sign_chrome.py"),
        )

    def test_icon_overlay_is_verified_before_signing(self) -> None:
        text = SIGN_RUNTIME.read_text(encoding="utf-8")
        helper = text.split("apply_public_runtime_icon() {", 1)[1].split(
            "\n}\n\nmanual_public_alpha_sign", 1
        )[0]

        self.assertIn('Resources/NeAntik.icns"', helper)
        self.assertIn('Contents/Resources"', helper)
        self.assertIn('cmp -s "$project_icon" "$runtime_icon"', helper)
        self.assertIn('-L "$project_icon"', helper)
        self.assertIn('-L "$runtime_resources"', helper)
        self.assertIn('-L "$runtime_icon"', helper)
        self.assertIn(".neantik-runtime-icon.XXXXXX", helper)
        self.assertIn('/bin/mv -f "$temporary_icon" "$runtime_icon"', helper)


if __name__ == "__main__":
    unittest.main()
