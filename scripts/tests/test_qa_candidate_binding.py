import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('qa_binding', Path(__file__).resolve().parents[1] / 'qa-candidate-binding.py')
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class CandidateBindingTests(unittest.TestCase):
    def setUp(self):
        self.candidate = dict(sha256='a' * 64, root='/private/tmp/neantik-own-qa',
            app='/private/tmp/neantik-own/NeAntik.app', archive='/private/tmp/neantik-own/qa.zip',
            profileSeedSHA256='b' * 64, managerSHA256='c' * 64, hostSHA256='d' * 64,
            version='0.8.26', build='138')
        self.plan = dict(archiveSHA256='a' * 64, root=self.candidate['root'], profileSeedSHA256='b' * 64)
        self.info = dict(NeAntikDevelopmentFixtureRoot=self.candidate['root'],
            CFBundleIdentifier='app.neantik.desktop.dev', CFBundleShortVersionString='0.8.26', CFBundleVersion='138')
        mapping = dict(appPath='app', archivePath='archive', dataRoot='root', archiveSHA256='sha256',
                       profilesSHA256='profileSeedSHA256', managerSHA256='managerSHA256', hostSHA256='hostSHA256')
        self.launcher = '\n'.join(f'static let {key} = "{self.candidate[value]}"' for key, value in mapping.items())
        self.launcher += '\nlet canonicalRoot = "/tmp/neantik-own-qa"'
        self.fixture = f'ROOT = Path("{self.candidate["root"]}")\nPROFILES_SHA256 = "{"b" * 64}"\nprint({{"candidateSHA256": "{"a" * 64}"}})'

    def check(self, **overrides):
        values = dict(candidate=self.candidate, plan=self.plan, info=self.info,
                      launcher=self.launcher, fixture=self.fixture)
        values.update(overrides)
        return MOD.validate(**values)

    def test_valid_binding_is_inert_and_not_release_qualification(self):
        result = self.check()
        self.assertEqual(result['status'], 'declarations-consistent')
        self.assertEqual(result['byteVerification'], 'not-performed')
        self.assertFalse(result['nativeLaunch'])
        self.assertFalse(result['releaseQualified'])

    def test_single_dot_mktemp_suffix_is_allowed_but_traversal_is_not(self):
        dotted = '/private/tmp/neantik-own-qa.XcU8LM'
        candidate = copy.deepcopy(self.candidate)
        plan = copy.deepcopy(self.plan)
        info = copy.deepcopy(self.info)
        candidate['root'] = plan['root'] = info['NeAntikDevelopmentFixtureRoot'] = dotted
        launcher = self.launcher.replace(
            'let canonicalRoot = "/tmp/neantik-own-qa"',
            'let canonicalRoot = "/tmp/neantik-own-qa.XcU8LM"').replace(
            '/private/tmp/neantik-own-qa', dotted)
        fixture = self.fixture.replace('/private/tmp/neantik-own-qa', dotted)
        self.assertEqual(self.check(candidate=candidate, plan=plan, info=info,
                                    launcher=launcher, fixture=fixture)['status'],
                         'declarations-consistent')
        candidate['root'] = '/private/tmp/neantik-own-qa..bad'
        with self.assertRaisesRegex(MOD.BindingError, 'invalid-root'):
            self.check(candidate=candidate, plan=plan, info=info,
                       launcher=launcher, fixture=fixture)

    def test_old_caption_is_rejected_even_with_correct_root(self):
        with self.assertRaisesRegex(MOD.BindingError, 'fixture-candidate-caption'):
            self.check(fixture=self.fixture.replace('a' * 64, 'e' * 64))

    def test_wrong_root_suffix_and_alias_are_rejected(self):
        for field, value in [('fixture', self.fixture.replace('own-qa', 'old-qa')),
                             ('launcher', self.launcher.replace('/tmp/neantik-own-qa', '/tmp/neantik-old-qa'))]:
            with self.subTest(field=field), self.assertRaises(MOD.BindingError):
                self.check(**{field: value})

    def test_plan_hash_root_and_seed_must_match(self):
        for key in self.plan:
            plan = copy.deepcopy(self.plan); plan[key] += 'wrong'
            with self.subTest(key=key), self.assertRaises(MOD.BindingError):
                self.check(plan=plan)

    def test_version_build_identity_and_embedded_root_must_match(self):
        for key in self.info:
            info = copy.deepcopy(self.info); info[key] += 'wrong'
            with self.subTest(key=key), self.assertRaises(MOD.BindingError):
                self.check(info=info)

    def test_transcribed_launcher_hash_and_seed_refused(self):
        for letter in ('a', 'b', 'c', 'd'):
            with self.subTest(letter=letter), self.assertRaises(MOD.BindingError):
                self.check(launcher=self.launcher.replace(letter * 64, 'f' * 64))

    def test_fixture_is_parsed_without_execution(self):
        self.assertEqual(self.check(fixture=self.fixture + '\nraise RuntimeError("must not run")')['status'], 'declarations-consistent')

    def test_missing_caption_is_not_silent_pass(self):
        with self.assertRaisesRegex(MOD.BindingError, 'fixture-candidate-caption'):
            self.check(fixture='\n'.join(self.fixture.splitlines()[:2]))
