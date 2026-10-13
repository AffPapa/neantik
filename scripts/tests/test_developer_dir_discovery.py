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
        fixtures = self.root / 'scripts/fixtures'; fixtures.mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/fixtures/swift-sdk-compatibility.swift', fixtures / 'swift-sdk-compatibility.swift')
        # Resolver's project root is normally one level above scripts/.
        self.script = self.root / 'scripts/resolver.sh'; self.script.write_text(text)
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin', FAKE_SELECTED=str(self.selected))
        self.env.pop('DEVELOPER_DIR', None); self.env.pop('NEANTIK_DEVELOPER_DIR_DIAGNOSTICS', None)

    def write_tool(self, name, content):
        p = self.bin / name; p.write_text(content); p.chmod(0o700)

    def installation(self, path, compiler='swiftlang-good clang-good', sdk='swiftlang-good clang-good', interface=True, probe=True):
        path.mkdir(parents=True, exist_ok=True)
        p = path / 'swiftc'; p.write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then\necho "Apple Swift version 6.3 (' + compiler + ')"\nexit 0\nfi\n[ "$1" = "-typecheck" ] || exit 9\nfor arg; do last="$arg"; done\n[ -f "$last" ] || exit 8\n[ -f "$DEVELOPER_DIR/probe-pass" ] || exit 7\n'); p.chmod(0o700)
        marker = path / 'probe-pass'
        if probe: marker.touch()
        elif marker.exists(): marker.unlink()
        interfaces = path / 'SDK/usr/lib/swift/Swift.swiftmodule'; interfaces.mkdir(parents=True, exist_ok=True)
        if interface: (interfaces / 'arm64-apple-macos.swiftinterface').write_text('// swift-compiler-version: Apple Swift version 6.3 (' + sdk + ')\n')
        return path

    def run_resolver(self, explicit=None, diagnostic=False):
        env = dict(self.env)
        if explicit is not None:env['DEVELOPER_DIR'] = str(explicit)
        if diagnostic:env['NEANTIK_DEVELOPER_DIR_DIAGNOSTICS'] = '1'
        return subprocess.run([shutil.which('zsh'), str(self.script)], env=env, text=True, capture_output=True, timeout=10)

    def test_versioned_candidate_is_found_after_actual_import_failures(self):
        self.installation(self.selected, probe=False)
        self.installation(self.apps/'Xcode_26.3.app/Contents/Developer', probe=False)
        good = self.installation(self.apps/'Xcode_26.4.app/Contents/Developer', sdk='swiftlang-older clang-older')
        result = self.run_resolver(diagnostic=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(good)+'\n')
        self.assertIn('compiler=swiftlang-good clang-good', result.stderr)

    def test_explicit_pin_has_no_automatic_fallback(self):
        bad = self.installation(self.selected, probe=False)
        self.installation(self.apps/'Xcode_26.4.app/Contents/Developer')
        result = self.run_resolver(explicit=bad)
        self.assertEqual(result.returncode, 69)
        self.assertEqual(result.stdout, '')
        self.installation(bad)
        result = self.run_resolver(explicit=bad)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(bad)+'\n')

    def test_absent_glob_empty_signatures_or_missing_arm64_remain_refused(self):
        for compiler,sdk,interface in [('no-signature','swiftlang-good clang-good',True),
                                       ('swiftlang-good clang-good','no-signature',True),
                                       ('swiftlang-good clang-good','swiftlang-good clang-good',False)]:
            with self.subTest(compiler=compiler,sdk=sdk,interface=interface):
                if self.selected.exists():shutil.rmtree(self.selected)
                self.installation(self.selected,compiler,sdk,interface)
                result = self.run_resolver()
                self.assertEqual(result.returncode,69,result.stderr)
                self.assertEqual(result.stdout,'')
                self.assertNotIn('no matches found', result.stderr)

    def test_equal_signatures_do_not_hide_an_actual_import_error(self):
        self.installation(self.selected, probe=False)
        result = self.run_resolver(diagnostic=True)
        self.assertEqual(result.returncode, 69)
        self.assertIn('SDK API typecheck failed', result.stderr)

    def test_different_stable_module_build_can_pass_real_probe(self):
        self.installation(self.selected, sdk='swiftlang-older clang-older')
        result = self.run_resolver(diagnostic=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.selected)+'\n')
        self.assertIn('SDK API typecheck passed', result.stderr)

    def test_missing_probe_or_old_package_compiler_is_refused(self):
        self.installation(self.selected)
        probe = self.root / 'scripts/fixtures/swift-sdk-compatibility.swift'
        probe.unlink()
        self.assertEqual(self.run_resolver().returncode, 69)
        probe.write_text('import Foundation\n')
        compiler = self.selected / 'swiftc'
        compiler.write_text(compiler.read_text().replace('version 6.3', 'version 6.1'))
        result = self.run_resolver(diagnostic=True)
        self.assertEqual(result.returncode, 69)
        self.assertIn('Swift 6.2 or newer required', result.stderr)

if __name__ == '__main__':unittest.main()
