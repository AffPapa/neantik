import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chromium_15680_privacy_derivation as privacy

PROJECT = Path(__file__).resolve().parents[2]

class PrivacyDerivationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neantik-privacy-layer-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = json.loads((PROJECT / privacy.MANIFEST).read_text())
        crc = json.loads((PROJECT / privacy.BASE['portableCRC']['file']).read_text())
        files = {privacy.MANIFEST, privacy.BASE['sourceContract']['file'], privacy.BASE['portableCRC']['file'],
                 'runtime/chromium-15680-build-evidence.json', 'runtime/chromium-15680-portable-crc.patch'}
        files.update(x['file'] for x in crc['inputs'].values())
        files.add(self.manifest['patch']['file'])
        files.update({'runtime/chromium-15680-privacy-v1-source-contract.json',
            'runtime/chromium-15680-rebase-plan.json', 'runtime/chromium-15680-source-adoption-v1.json',
            'runtime/chromium-15680-neantik.patch', 'runtime/chromium-15680-devtools-typescript6.patch',
            'runtime/chromium-15680-v8-scope-iterator-compat.patch', 'runtime/chromium-15680-deps-lock.json',
            'runtime/chromium-15680-DEPS', 'runtime/chromium-15680-args.gn', 'runtime/chromium-15680-gclient',
            'runtime/chromium-15680-gclient_entries', 'runtime/chromium-15680-gcs_entries',
            'runtime/licenses/Chromium-LICENSE', 'runtime/security-baseline.json',
            'runtime/nevision-patches/series.json', 'runtime/apple-device-tuples.json'})
        base_contract = json.loads((PROJECT / privacy.BASE['sourceContract']['file']).read_text())
        files.add(f"runtime/security-baselines/{base_contract['securityBaselineSHA256']}.json")
        if self.manifest['link'] is not None:
            files.update(self.manifest['link'][key]['file'] for key in ('recipe', 'responseFile'))
            files.update(x['members']['file'] for x in self.manifest['link']['thinArchives'].values())
            rebuild = self.manifest['link']['archiveRebuilds']; files.add(rebuild['file'])
            files.update(x['memberInputs']['file'] for x in json.loads((PROJECT / rebuild['file']).read_text())['archives'])
        files.update(x['file'] for x in self.manifest['licenses']); files.add(self.manifest['notice']['file'])
        for x in self.manifest['files'] + self.manifest['supplementalSources']:
            files.update(x[k]['file'] for k in ('preimage', 'postimage', 'recipe') if k in x)
        for name in files:
            target = self.root / name; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, target)

    def binding(self):
        path = self.root / privacy.MANIFEST
        path.write_text(json.dumps(self.manifest))
        return {'file': privacy.MANIFEST, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

    def verify(self, **options):
        return privacy.verify(self.root, self.binding(), require_link=False, **options)

    def test_recorded_compiled_layer_is_not_release_or_link_admission(self):
        self.assertEqual(len(self.verify()['files']), len(privacy.SOURCES))
        self.manifest['status'] = 'compiled-link-pending'; self.manifest['link'] = None
        with self.assertRaisesRegex(ValueError, 'link not complete'):
            privacy.verify(self.root, self.binding())

    def test_historical_baseline_remains_bound_after_release_refresh(self):
        base = json.loads((self.root / privacy.BASE['sourceContract']['file']).read_text())
        digest = base['securityBaselineSHA256']
        archive = self.root / 'runtime/security-baselines' / f'{digest}.json'
        self.assertNotEqual(hashlib.sha256((self.root / 'runtime/security-baseline.json').read_bytes()).hexdigest(), digest)
        privacy.verify_contract(self.root)
        original = archive.read_bytes()
        for scenario in ('missing', 'modified', 'symlink'):
            with self.subTest(scenario=scenario):
                archive.unlink()
                if scenario == 'modified': archive.write_bytes(original + b' ')
                if scenario == 'symlink': archive.symlink_to(self.root / 'runtime/security-baseline.json')
                with self.assertRaises(ValueError): privacy.verify_contract(self.root)
                if archive.exists() or archive.is_symlink(): archive.unlink()
                archive.write_bytes(original)

    def test_full_recorded_derivation_and_lock_bind_new_framework(self):
        contract, layer = privacy.verify_contract(self.root)
        provenance = self.root / 'provenance.json'
        provenance.write_text(json.dumps(privacy.expected_provenance(self.root)))
        lock = privacy.expected_lock(provenance, self.root)
        privacy.verify_lock(lock, provenance, self.root)
        privacy.verify_lock_binding(lock, self.root)
        self.assertEqual(lock['binaryBinding']['unsignedFrameworkSHA256'], layer['link']['frameworkSHA256'])
        lock['binaryBinding']['unsignedFrameworkSHA256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'binding mismatch'): privacy.verify_lock_binding(lock, self.root)

    def test_old_lock_cannot_admit_new_layer_and_new_layer_cannot_select_base_framework(self):
        with self.assertRaises(ValueError): privacy.verify_lock_binding({'variant': 'old-base'}, self.root)
        crc = json.loads((self.root / privacy.BASE['portableCRC']['file']).read_text())
        self.manifest['link']['frameworkSHA256'] = crc['outputs']['frameworkSHA256']
        with self.assertRaisesRegex(ValueError, 'binary binding mismatch'):
            privacy.verify(self.root, self.binding())

    def test_missing_font_source_and_changed_archive_recipe_refuse(self):
        original = json.loads(json.dumps(self.manifest))
        self.manifest['supplementalSources'].pop()
        with self.assertRaisesRegex(ValueError, 'supplemental'): privacy.verify(self.root, self.binding())
        self.manifest = original
        entry = self.manifest['link']['archiveRebuilds']; path = self.root / entry['file']
        value = json.loads(path.read_text()); value['archives'][0]['freshCreationRequired'] = False
        path.write_text(json.dumps(value)); entry['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'recipe/input/result mismatch'):
            privacy.verify(self.root, self.binding())

    def test_successful_link_requires_integer_zero_and_original_recipient_response(self):
        original = json.loads(json.dumps(self.manifest))
        self.manifest['link']['exitCode'] = False
        with self.assertRaisesRegex(ValueError, 'link receipt required'):
            privacy.verify(self.root, self.binding())
        self.manifest = original
        entry = self.manifest['link']['responseFile']; path = self.root / entry['file']
        path.write_text(path.read_text() + ' foreign.o')
        entry['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'published recipient source offer'):
            privacy.verify(self.root, self.binding())

    def test_exact_packaged_closure_refuses_missing_modified_or_extra_evidence(self):
        package = self.root / 'bundle-evidence'
        privacy.copy_evidence(self.root, package)
        privacy.verify_packaged_evidence(self.root, package)
        extra = package / 'chromium-15680-source-evidence/privacy-policy-v1/unreviewed.js'
        extra.write_text('unreviewed')
        with self.assertRaisesRegex(ValueError, 'extra or missing'): privacy.verify_packaged_evidence(self.root, package)
        extra.unlink()
        path = package / 'chromium-15680-source-evidence/privacy-policy-v1/derivation.json'
        path.write_text('changed')
        with self.assertRaises(ValueError): privacy.verify_packaged_evidence(self.root, package)

    def test_missing_duplicate_extra_and_wrong_object_refuse(self):
        original = json.loads(json.dumps(self.manifest))
        for mutation in ('missing', 'duplicate', 'extra', 'object'):
            with self.subTest(mutation=mutation):
                self.manifest = json.loads(json.dumps(original))
                if mutation == 'missing': self.manifest['files'].pop()
                elif mutation == 'duplicate': self.manifest['files'][1] = self.manifest['files'][0]
                elif mutation == 'extra': self.manifest['files'].append(self.manifest['files'][0])
                else: self.manifest['files'][0]['object'] = 'obj/foreign.o'
                with self.assertRaises(ValueError): self.verify()

    def test_bool_exit_code_and_repin_base_refuse(self):
        self.manifest['files'][0]['compileExitCode'] = False
        with self.assertRaises(ValueError): self.verify()
        self.manifest['files'][0]['compileExitCode'] = 0
        self.manifest['base']['sourceOfferManifestSHA256'] = 'a' * 64
        with self.assertRaises(ValueError): self.verify()

    def test_hash_consistent_wrong_compile_output_refuses(self):
        entry = self.manifest['files'][0]['recipe']; path = self.root / entry['file']
        recipe = json.loads(path.read_text()); recipe['argv'][-1] = 'obj/foreign.o'
        path.write_text(json.dumps(recipe)); entry['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'compile command'): self.verify()

    def test_hash_consistent_patch_with_extra_hunk_refuses(self):
        entry = self.manifest['patch']; path = self.root / entry['file']
        path.write_text(path.read_text() + '\nextra unreviewed hunk\n')
        entry['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'exactly reproduce'): self.verify()

    def test_symlinked_image_and_path_escape_refuse(self):
        entry = self.manifest['files'][0]['postimage']; path = self.root / entry['file']
        target = path.with_suffix('.held'); path.rename(target); path.symlink_to(target.name)
        with self.assertRaisesRegex(ValueError, 'symlink'): self.verify()
        path.unlink(); target.rename(path)
        entry['file'] = '../outside'
        with self.assertRaises(ValueError): self.verify()

class ThinArchiveParserTests(unittest.TestCase):
    def header(self, name, size):
        return (name.ljust(16) + '0'.ljust(12) + '0'.ljust(6) + '0'.ljust(6) +
                '644'.ljust(8) + str(size).ljust(10) + "`\n").encode()

    def archive(self, names):
        table = ''.join(name + '/\n' for name in names).encode()
        result = b'!<thin>\n' + self.header('//', len(table)) + table + (b'\n' if len(table) % 2 else b'')
        offset = 0
        for name in names:
            result += self.header('/' + str(offset), 12_345)
            offset += len(name.encode()) + 2
        return result

    def test_real_thin_members_have_no_object_payload(self):
        self.assertEqual(privacy.thin_members(self.archive(['own/a.o', 'own/b.o'])), ['own/a.o', 'own/b.o'])
        self.assertEqual(privacy.thin_members(self.archive(['same.o', 'same.o'])), ['same.o', 'same.o'])

    def test_truncation_offsets_escape_and_nested_archives_refuse(self):
        valid = self.archive(['own/a.o'])
        cases = [valid[:-1], b'!<arch>\n', self.archive(['../outside.o']),
                 valid[:-60] + self.header('/999999', 10),
                 valid[:-60] + self.header('/0:0', 10)]
        for value in cases:
            with self.subTest(value=value[-60:]):
                with self.assertRaises(ValueError): privacy.thin_members(value)

if __name__ == '__main__': unittest.main()
