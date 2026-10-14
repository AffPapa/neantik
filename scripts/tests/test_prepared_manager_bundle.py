import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepared_manager_bundle as prepared
import release_candidate_location as location


class PreparedManagerBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve(); (self.project / 'dist').mkdir()
        self.root = location.create(self.project)
        self.env = {'NEANTIK_RELEASE_CHANNEL':'public-alpha', 'NEANTIK_SIGNING_IDENTITY':'A'*40}
        self.source = {'commit':'b'*40, 'tree':'c'*40}
        self.bundle = {'inventorySHA256':'d'*64, 'version':'0.8.13', 'build':'125', 'architecture':'arm64', 'signerSHA1':'A'*40}
        self.reads = 0

    def stage(self, op):
        def bundle_reader(app, signer):
            self.reads += 1
            return self.bundle.copy()
        return prepared.stage(op, self.project, self.root, self.env, lambda _: self.source.copy(), bundle_reader)

    def finish(self):
        self.stage('begin'); (self.root / 'NeAntik.app').mkdir(); self.stage('finish')

    def test_finish_and_verify_are_unqualified_and_allocate_no_authority(self):
        self.finish()
        self.assertIs(self.stage('verify')['releaseQualified'], False)
        self.assertFalse((self.root/'fingerprint-enrollment.json').exists())
        self.assertFalse((self.root/'prepared-enrollment-attempt.json').exists())
        self.assertEqual((self.root/'prepared-bundle.json').stat().st_mode & 0o777, 0o600)

    def test_source_or_signing_options_change_refuses_before_bundle_read(self):
        self.finish(); count=self.reads
        self.source['tree']='e'*40
        with self.assertRaises(ValueError):self.stage('verify')
        self.assertEqual(self.reads,count)
        self.source['tree']='c'*40; self.env['NEANTIK_BROWSER_DATA_BACKUP_ENABLED']='1'
        with self.assertRaises(ValueError):self.stage('verify')
        self.assertEqual(self.reads,count)

    def test_changed_bundle_version_inventory_and_architecture_refuse(self):
        self.finish()
        for key, bad in [('version','9.0.0'),('build','126'),('inventorySHA256','e'*64),('architecture','x86_64'),('signerSHA1','B'*40)]:
            with self.subTest(key=key):
                old=self.bundle[key]; self.bundle[key]=bad
                with self.assertRaises(ValueError):self.stage('verify')
                self.bundle[key]=old

    def test_duplicate_unknown_boolean_and_unsafe_receipts_refuse(self):
        self.finish(); path=self.root/'prepared-bundle.json'; original=path.read_bytes()
        for raw in [b'{"schemaVersion":1,"schemaVersion":1}', b'{"schemaVersion":true}', original[:-2]+b',"extra":1}\n']:
            path.write_bytes(raw)
            with self.assertRaises(ValueError):self.stage('verify')
        path.write_bytes(original); path.chmod(0o644)
        with self.assertRaises(ValueError):self.stage('verify')
        path.chmod(0o600); path.unlink(); path.symlink_to(self.root/'preparation-source.json')
        with self.assertRaises(OSError):self.stage('verify')

    def test_start_and_finish_never_overwrite_existing_candidate_or_receipt(self):
        self.finish()
        with self.assertRaises(ValueError):self.stage('begin')
        with self.assertRaises(FileExistsError):self.stage('finish')

    def test_missing_receipt_and_adhoc_or_unknown_options_refuse(self):
        with self.assertRaises(FileNotFoundError):self.stage('verify')
        self.env['NEANTIK_LOCAL_ADHOC']='1'
        with self.assertRaises(ValueError):self.stage('begin')
        self.env['NEANTIK_LOCAL_ADHOC']='0'; self.env['NEANTIK_RELEASE_CHANNEL']='other'
        with self.assertRaises(ValueError):self.stage('begin')

    def test_enrollment_failure_is_not_automatically_restarted(self):
        self.finish(); self.assertEqual(self.stage('reserve-enrollment')['status'],'new-enrollment')
        with self.assertRaises(ValueError):self.stage('reserve-enrollment')
        prepared.write_once(self.root/'fingerprint-enrollment.json', {'schemaVersion':1})
        self.assertEqual(self.stage('reserve-enrollment')['status'],'reuse-enrollment')
        (self.root/'fingerprint-enrollment.json').unlink(); (self.root/'fingerprint-enrollment.json').symlink_to(self.root/'preparation-source.json')
        with self.assertRaises(ValueError):self.stage('reserve-enrollment')

    def test_mode_order_keeps_build_and_native_qualification_separate(self):
        scripts=Path(__file__).resolve().parents[1]
        text=(scripts/'prepare-direct-manager-update.sh').read_text()
        self.assertIn('export PYTHONDONTWRITEBYTECODE=1',text)
        self.assertLess(text.index('prepared_manager_bundle.py" finish'),text.index('native-qa-readiness.py'))
        self.assertLess(text.index('native-qa-readiness.py'),text.index('enroll-direct-fingerprint-authority.sh'))
        qualify=(scripts/'qualify-prepared-manager.sh').read_text()
        self.assertIn('export PYTHONDONTWRITEBYTECODE=1',qualify)
        for banned in ['swift build','ditto','codesign --sign','strip -S','package-update-helpers.py']:
            self.assertNotIn(banned,qualify)
        self.assertLess(qualify.index('native-qa-readiness.py'),qualify.index('reserve-enrollment'))

    def test_actual_qualification_shell_stops_before_reservation_on_pressure_or_unknown(self):
        fixture=self.project/'scripts'; fixture.mkdir()
        text=(Path(__file__).resolve().parents[1]/'qualify-prepared-manager.sh').read_text()
        script=fixture/'qualify-prepared-manager.sh'; script.write_text(text)
        executable=self.project/'bin'; executable.mkdir()
        stub=executable/'python3'
        stub.write_text('#!'+sys.executable+'\nimport os,sys\nfrom pathlib import Path\nwith Path(os.environ["CALL_LOG"]).open("a") as f:f.write(" ".join(sys.argv[1:])+"\\n")\nif any("native-qa-readiness.py" in x for x in sys.argv):sys.exit(int(os.environ["READINESS_EXIT"]))\nif "verify" not in sys.argv:sys.exit(99)\nprint("{}")\n')
        stub.chmod(0o700)
        for code in [75,78]:
            log=self.project/('calls-'+str(code))
            env=os.environ.copy(); env.update(PATH=str(executable)+':'+env.get('PATH',''),NEANTIK_DIRECT_CANDIDATE_ROOT=str(self.root),CALL_LOG=str(log),READINESS_EXIT=str(code))
            result=subprocess.run(['/bin/zsh',str(script)],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,code)
            calls=log.read_text()
            self.assertIn('prepared_manager_bundle.py verify',calls)
            self.assertIn('native-qa-readiness.py --check',calls)
            self.assertNotIn('reserve-enrollment',calls)
            self.assertFalse((self.root/'prepared-enrollment-attempt.json').exists())


if __name__=='__main__':unittest.main()
