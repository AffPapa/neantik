"""The public manager must not publish Swift object-file path debug maps."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class ReleaseDebugPathRemovalTests(unittest.TestCase):
    def test_packagers_strip_only_staged_manager_after_copy(self):
        for name, destination in (
            ('package-app.sh', '$MACOS_DIR/NeAntik'),
            ('prepare-direct-manager-update.sh', '$CANDIDATE_APP/Contents/MacOS/NeAntik'),
        ):
            text = (ROOT / 'scripts' / name).read_text()
            copy = f'cp "$MANAGER_BINARY" "{destination}"'
            strip = f'xcrun strip -S "{destination}"'
            self.assertEqual(text.count(strip), 1)
            self.assertLess(text.index(copy), text.index(strip))
            self.assertNotIn('strip -S "$MANAGER_BINARY"', text)

    @unittest.skipUnless(sys.platform == 'darwin', 'Mach-O stripping requires macOS')
    def test_stripped_synthetic_executable_still_runs(self):
        with tempfile.TemporaryDirectory(prefix='neantik-strip-contract-') as directory:
            root = Path(directory)
            source = root / 'main.c'
            binary = root / 'probe'
            source.write_text('int main(void) { return 17; }\n')
            subprocess.run(['xcrun', 'clang', '-g', str(source), '-o', str(binary)], check=True, capture_output=True)
            self.assertIn(directory.encode(), binary.read_bytes())
            subprocess.run(['xcrun', 'strip', '-S', str(binary)], check=True, capture_output=True)
            self.assertNotIn(directory.encode(), binary.read_bytes())
            self.assertEqual(subprocess.run([str(binary)], capture_output=True).returncode, 17)

if __name__ == '__main__':
    unittest.main()
