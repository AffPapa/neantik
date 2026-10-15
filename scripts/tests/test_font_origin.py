import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('font_origin', ROOT/'scripts/runtime-platform/analyze-font-origin.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture():
    observation = {key: True for key in MODULE.CONTROLS}
    observation.update(schemaVersion=1, registrationScope='process', systemFontInstallation=False,
                       nativeFamilyLookupAllowedAfterCollision=False, systemFamilyOriginClass='protected-system-file',
                       cachedAllowedReads=10000, protectedDescriptorCount=1, restrictedSamples=[])
    for sample in MODULE.SAMPLES:
        observation['restrictedSamples'].append(dict(sample=sample, shapingCompleted=True, actualBitmapDrawn=True,
            missingGlyph=False, lastResortUsed=False, glyphs=3, distinctGlyphCount=3,
            strictPolicyRejectedRuns=0, originClasses={'protected-system-file': 1}))
    receipt = dict(schemaVersion=1, status='native-primitive-complete', exitCode=0, actualBrowser=False,
                   productionFilesChanged=False, sourceSHA256={key: 'a'*64 for key in MODULE.SOURCES})
    readiness = dict(eligibleForAttempt=True, memoryPressure=1, thermalState=0, reasons=[])
    return observation, receipt, readiness


class FontOriginTests(unittest.TestCase):
    def test_positive_contract(self):
        self.assertTrue(MODULE.verify(*fixture())['passed'])

    def test_each_actual_control_is_required(self):
        for key in MODULE.CONTROLS:
            with self.subTest(control=key):
                observation, receipt, readiness = fixture()
                observation[key] = False
                self.assertFalse(MODULE.verify(observation, receipt, readiness)['passed'])

    def test_aggregate_success_cannot_hide_missing_glyphs_or_contexts(self):
        mutations = [lambda o: o['restrictedSamples'].pop(),
                     lambda o: o['restrictedSamples'][2].update(missingGlyph=True),
                     lambda o: o['restrictedSamples'][2].update(lastResortUsed=True),
                     lambda o: o['restrictedSamples'][2].update(distinctGlyphCount=1),
                     lambda o: o['restrictedSamples'][2].update(actualBitmapDrawn=False),
                     lambda o: o['restrictedSamples'][2].update(originClasses={'other-file': 1}),
                     lambda o: o.update(nativeFamilyLookupAllowedAfterCollision=True),
                     lambda o: o.update(registrationScope='session')]
        for mutate in mutations:
            observation, receipt, readiness = fixture()
            mutate(observation)
            self.assertFalse(MODULE.verify(observation, receipt, readiness)['passed'])

    def test_failure_timeout_and_unknown_admission_never_pass(self):
        observation, receipt, readiness = fixture()
        for field, value in [('status', 'owned-process-timeout'), ('exitCode', -10), ('actualBrowser', True), ('sourceSHA256', {})]:
            changed = copy.deepcopy(receipt); changed[field] = value
            self.assertFalse(MODULE.verify(observation, changed, readiness)['passed'])
        for pressure in (None, 2, 4):
            changed = copy.deepcopy(readiness); changed['memoryPressure'] = pressure
            self.assertFalse(MODULE.verify(observation, receipt, changed)['passed'])
        self.assertFalse(MODULE.verify({}, {}, {})['passed'])


if __name__ == '__main__':
    unittest.main()
