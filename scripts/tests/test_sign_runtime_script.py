import unittest
import re
import shlex
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SIGN_RUNTIME = ROOT / "scripts" / "sign-runtime.sh"


class SignRuntimeScriptTests(unittest.TestCase):
    @unittest.skipUnless(Path('/bin/zsh').is_file(), 'Requires zsh for the actual cleanup trap')
    def test_candidate_cleanup_preserves_failure_and_removes_only_successful_inputs(self):
        text = (ROOT / 'scripts/prepare-direct-runtime-candidate.sh').read_text()
        cleanup = re.search(r'cleanup\(\) \{.*?\n\}', text, re.S).group(0)
        trap = re.search(r"^trap 'cleanup \$\?' EXIT$", text, re.M).group(0)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unrelated = root / 'unrelated'
            unrelated.write_text('keep')
            for status in (23, 0):
                staged = root / ('staged-' + str(status))
                staged.mkdir()
                (staged / 'signed-runtime').write_text('retained bytes')
                script = ('set -euo pipefail\nSIGNED_RUNTIME_ROOT=' + shlex.quote(str(staged))
                          + '\n' + cleanup + '\n' + trap + '\nexit ' + str(status))
                result = subprocess.run(['/bin/zsh', '-f', '-c', script], capture_output=True)
                self.assertEqual(result.returncode, status)
                self.assertEqual(staged.exists(), status != 0)
                self.assertEqual(unrelated.read_text(), 'keep')

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
