"""Real resolver process with disposable SDK/compiler fixtures; no native build."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

@unittest.skipUnless(shutil.which('zsh'), 'The developer-dir resolver targets macOS zsh')
class DeveloperDirectoryDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.apps = self.root / 'Applications'; self.apps.mkdir()
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.selected = self.root / 'SelectedDeveloper'
        self.write_tool('xcode-select', '#!/bin/sh\nprintf "%s\\n" "$FAKE_SELECTED"\n')
        self.write_tool('xcrun', '#!/bin/sh\ncase "$*" in\n"--find swiftc") echo "$DEVELOPER_DIR/swiftc";;\n"--sdk macosx --show-sdk-path") echo "$DEVELOPER_DIR/SDK";;\n*) exit 1;;\nesac\n')
        text = (ROOT / 'scripts/resolve-compatible-developer-dir.sh').read_text().replace('/Applications/', str(self.apps) + '/')
        self.script = self.root / 'resolver.sh'; self.script.write_text(text)
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin', FAKE_SELECTED=str(self.selected))
        self.env.pop('DEVELOPER_DIR', None); self.env.pop('NEANTIK_DEVELOPER_DIR_DIAGNOSTICS', None)

    def write_tool(self, name, content):
        p = self.bin / name; p.write_text(content); p.chmod(0o700)

    def installation(self, path, compiler='swiftlang-good clang-good', sdk='swiftlang-good clang-good', interface=True):
        path.mkdir(parents=True, exist_ok=True)
        p = path / 'swiftc'; p.write_text('#!/bin/sh\necho "Apple Swift version 6.3 (' + compiler + ')"\n'); p.chmod(0o700)
        interfaces = path / 'SDK/usr/lib/swift/Swift.swiftmodule'; interfaces.mkdir(parents=True, exist_ok=True)
        if interface: (interfaces / 'arm64-apple-macos.swiftinterface').write_text('// swift-compiler-version: Apple Swift version 6.3 (' + sdk + ')\n')
        return path

    def run_resolver(self, explicit=None, diagnostic=False):
        env = dict(self.env)
        if explicit is not None:env['DEVELOPER_DIR'] = str(explicit)
        if diagnostic:env['NEANTIK_DEVELOPER_DIR_DIAGNOSTICS'] = '1'
        return subprocess.run([shutil.which('zsh'), str(self.script)], env=env, text=True, capture_output=True, timeout=10)

    def test_versioned_matching_candidate_is_found_after_mismatches(self):
        self.installation(self.selected, sdk='swiftlang-wrong clang-good')
        self.installation(self.apps/'Xcode_26.3.app/Contents/Developer', sdk='swiftlang-wrong clang-good')
        good = self.installation(self.apps/'Xcode_26.4.app/Contents/Developer')
        result = self.run_resolver(diagnostic=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(good)+'\n')
        self.assertIn('compiler=swiftlang-good clang-good', result.stderr)

    def test_explicit_pin_has_no_automatic_fallback(self):
        bad = self.installation(self.selected, sdk='swiftlang-other clang-good')
        self.installation(self.apps/'Xcode_26.4.app/Contents/Developer')
        result = self.run_resolver(explicit=bad)
        self.assertEqual(result.returncode, 69)
        self.assertEqual(result.stdout, '')
        self.installation(bad)
        result = self.run_resolver(explicit=bad)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(bad)+'\n')

    def test_absent_glob_empty_or_different_signatures_remain_refused(self):
        for compiler,sdk,interface in [('swiftlang-good clang-good','swiftlang-other clang-good',True),
                                       ('no-signature','swiftlang-good clang-good',True),
                                       ('swiftlang-good clang-good','no-signature',True),
                                       ('swiftlang-good clang-good','swiftlang-good clang-other',True),
                                       ('swiftlang-good clang-good','swiftlang-good clang-good',False)]:
            with self.subTest(compiler=compiler,sdk=sdk,interface=interface):
                if self.selected.exists():shutil.rmtree(self.selected)
                self.installation(self.selected,compiler,sdk,interface)
                result = self.run_resolver()
                self.assertEqual(result.returncode,69,result.stderr)
                self.assertEqual(result.stdout,'')
                self.assertNotIn('no matches found', result.stderr)

if __name__ == '__main__':unittest.main()
