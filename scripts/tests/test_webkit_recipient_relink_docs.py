import pathlib
import os
import re
import subprocess
import tempfile
import unittest


class RecipientRelinkDocumentationTests(unittest.TestCase):
    def test_pinned_backup_signing_sequence_keeps_original_profile(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        text = (root / 'docs/WEBKIT_RECIPIENT_RELINK.md').read_text()
        selection = text.index('pinned_backup=0')
        profile = text.index('NEANTIK_DIRECT_PROVISIONING_PROFILE="$shipped/Contents/embedded.provisionprofile"')
        preflight = text.index('direct_backup_signing.py preflight "$shipped" "$identity"')
        move = text.index('mv "$host" "$work/original-WebKit-host.app"')
        signing = 'direct_backup_signing.py sign "$copy" "$identity"'
        initial = text.index(signing, move)
        resign = text.index('scripts/resign-webkit-recipient-runtime.py')
        package = text.index('scripts/package-webkit-host.py --recipient-relink')
        final = text.index(signing, package)
        verify = text.index('codesign --verify --deep --strict "$copy"', final)
        self.assertTrue(selection < profile < preflight < move < initial < resign < package < final < verify)
        self.assertIn('NEANTIK_BROWSER_DATA_BACKUP_ENABLED=1', text[selection:preflight])
        self.assertIn('backup_state=$(python3 -B scripts/direct_backup_signing.py state "$shipped") || exit 1', text[selection:preflight])
        self.assertIn('if [ "$backup_state" != "enabled" ]; then', text[selection:preflight])
        self.assertIn('if [ "$pinned_backup" -eq 1 ]; then', text[package:final])
        self.assertIn('else\n  codesign --force', text[final:verify])

    def test_failed_preflight_stops_before_copy_or_sign(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        text = (root / 'docs/WEBKIT_RECIPIENT_RELINK.md').read_text()
        blocks = re.findall(r'```bash\n(.*?)```', text, re.S)
        block = next(b for b in blocks if 'pinned_backup=0' in b)
        with tempfile.TemporaryDirectory() as temp:
            bindir = pathlib.Path(temp)
            codesign = bindir / 'codesign'
            codesign.write_text('#!/bin/sh\nexit 0\n')
            python = bindir / 'python3'
            python.write_text('#!/bin/sh\ncase "$3" in state) echo enabled; exit 0;; preflight) exit 23;; *) exit 99;; esac\n')
            codesign.chmod(0o700)
            python.chmod(0o700)
            env = dict(os.environ, PATH=str(bindir) + ':/usr/bin:/bin', shipped='/tmp/synthetic.app',
                       identity='474f7c78f33ee324c24f6f5ae0443eb713e85e60')
            result = subprocess.run(['/bin/bash', '-c', block + '\nprintf REACHED_COPY'], env=env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('REACHED_COPY', result.stdout)


if __name__ == '__main__':
    unittest.main()
