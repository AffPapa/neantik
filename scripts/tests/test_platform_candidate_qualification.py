import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "runtime-platform/qualify-candidate.py"
SPEC = importlib.util.spec_from_file_location("platform_candidate_qualification", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
IDENTITY_PATH = SOURCE.parent / 'fixtures/vector-semantics/verify-identity-m156.py'
IDENTITY_SPEC = importlib.util.spec_from_file_location('identity_oracle', IDENTITY_PATH)
IDENTITY = importlib.util.module_from_spec(IDENTITY_SPEC)
IDENTITY_SPEC.loader.exec_module(IDENTITY)


class PlatformQualificationTests(unittest.TestCase):
    def reference_fixture(self):
        policy_hash = MODULE.digest(IDENTITY.POLICY_PATH)
        binding = {'runtimeVersion': '155.0.8059.40', 'runtimeExecutableSHA256': 'a' * 64,
                   'runtimeFrameworkSHA256': 'b' * 64, 'policySHA256': policy_hash}
        js = {'userAgent': 'owned synthetic Chrome control', 'languages': ['en-US'], 'deviceMemory': 8}
        headers = {k: None for k in IDENTITY.ABSENT_HEADERS}
        headers.update({'user-agent': js['userAgent'], 'accept-language': 'en-US,en;q=0.9'})
        reference = {'runtimeVersion': binding['runtimeVersion'], 'executableSHA256': 'a' * 64,
                     'runtimeFrameworkSHA256': 'b' * 64, 'candidateBindingSHA256': 'c' * 64,
                     'headed': True, 'cleanupVerified': True, 'documentEvidence': {'loaded': True},
                     'mode': 'unconfigured', 'label': IDENTITY.POLICY['label'],
                     'data': {'js': js, 'worker': {'js': js, 'http': {'via': 'worker', 'headers': headers}}}}
        return reference, binding

    def test_reference_requires_bound_real_operation_and_explicit_absences(self):
        reference, binding = self.reference_fixture()
        self.assertTrue(IDENTITY.reference_valid(reference, binding, 'c' * 64))
        self.assertFalse(IDENTITY.reference_valid(None, binding, 'c' * 64))
        for key in reference:
            bad = copy.deepcopy(reference); bad.pop(key)
            self.assertFalse(IDENTITY.reference_valid(bad, binding, 'c' * 64), key)
        for key in binding:
            bad = dict(binding); bad[key] = 'wrong'
            self.assertFalse(IDENTITY.reference_valid(reference, bad, 'c' * 64), key)
        for key in IDENTITY.ABSENT_HEADERS:
            for value in ('missing', 'unexpected'):
                bad = copy.deepcopy(reference); h = bad['data']['worker']['http']['headers']
                if value == 'missing': h.pop(key)
                else: h[key] = 'present'
                self.assertFalse(IDENTITY.reference_valid(bad, binding, 'c' * 64), key)
        for field, value in [('mode', 'neantik-configured'), ('headed', False), ('cleanupVerified', False),
                             ('runtimeVersion', '155.0.8059.39'), ('label', 'foreign')]:
            bad = dict(reference, **{field: value})
            self.assertFalse(IDENTITY.reference_valid(bad, binding, 'c' * 64), field)
        bad = copy.deepcopy(reference); bad['data']['worker'] = {'error': 'timeout'}
        self.assertFalse(IDENTITY.reference_valid(bad, binding, 'c' * 64))
        for path in [('documentEvidence',), ('data',), ('data','worker'), ('data','worker','js'),
                     ('data','worker','http'), ('data','worker','http','headers'), ('data','worker','js','languages')]:
            for value in (None, [], 1):
                bad = copy.deepcopy(reference); target = bad
                for key in path[:-1]: target = target[key]
                target[path[-1]] = value
                self.assertFalse(IDENTITY.reference_valid(bad, binding, 'c' * 64), path)

    def test_candidate_missing_header_is_not_observed_absence(self):
        reference, binding = self.reference_fixture()
        # Other identity signals intentionally incomplete; isolate the absence assertion.
        candidate = copy.deepcopy(reference)
        good = IDENTITY.verify(candidate, reference, binding, 'c' * 64)
        self.assertNotIn('worker:observed-upstream-hint-availability', good['issues'])
        for key in IDENTITY.ABSENT_HEADERS:
            bad = copy.deepcopy(candidate); bad['data']['worker']['http']['headers'].pop(key)
            self.assertIn('worker:observed-upstream-hint-availability',
                          IDENTITY.verify(bad, reference, binding, 'c' * 64)['issues'])

    def test_resumed_reference_requires_source_archive_and_policy(self):
        reference, binding = self.reference_fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); entries = []
            for name in ('identity-probe.js', 'run-headed-m156.mjs'):
                original = root / 'vector-semantics' / name; original.parent.mkdir(exist_ok=True)
                original.write_text('owned synthetic '+name)
                sha = MODULE.digest(original); archive = root / 'fixture-source-archive/blobs' / sha
                archive.parent.mkdir(parents=True, exist_ok=True); archive.write_bytes(original.read_bytes())
                entries.append({'path': 'vector-semantics/'+name, 'sha256': sha, 'bytes': original.stat().st_size})
            reference.update(probeSHA256=entries[0]['sha256'], runnerSHA256=entries[1]['sha256'])
            manifest = MODULE.hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode()).hexdigest()
            reference.update(fixtureProvenance={'files': entries, 'manifestSHA256': manifest},
                             fixtureSourceArchive={'manifestSHA256': manifest})
            path = root / 'binding.json'; MODULE.write_once(path, binding)
            reference['candidateBindingSHA256'] = MODULE.digest(path)
            valid = lambda r: MODULE.reference_binding_matches(r, binding, path, IDENTITY.POLICY_PATH, root)
            self.assertTrue(valid(reference))
            for field in ('fixtureProvenance', 'fixtureSourceArchive', 'candidateBindingSHA256', 'probeSHA256', 'runnerSHA256'):
                bad = copy.deepcopy(reference); bad.pop(field)
                self.assertFalse(valid(bad), field)
            for entry in entries:
                bad = copy.deepcopy(reference)
                bad['fixtureProvenance']['files'] = [x for x in entries if x['path']!=entry['path']]
                self.assertFalse(valid(bad), entry['path'])
            archive.write_text('corrupted archive')
            self.assertFalse(valid(reference))

    def test_failed_identity_capture_emits_json_fail_without_mutating_missing_fields(self):
        reference, rb = self.reference_fixture()
        candidate = copy.deepcopy(reference)
        candidate['data']['worker']['http']['headers'].pop(IDENTITY.ABSENT_HEADERS[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); capture = root / 'identity-observations.json'
            rb_path = root / 'reference-binding.json'; MODULE.write_once(rb_path, rb)
            reference['candidateBindingSHA256'] = MODULE.digest(rb_path)
            (root/'m156-control-fresh-chrome-identity-observations.json').write_text(json.dumps(reference))
            capture.write_text(json.dumps(candidate))
            binding = root / 'candidate-binding.json'; MODULE.write_once(binding, rb)
            env = dict(os.environ, NEANTIK_PLATFORM_BINDING=str(binding),
                       NEANTIK_PLATFORM_CHROME_REFERENCE_BINDING=str(rb_path))
            result = subprocess.run([sys.executable, '-B', str(IDENTITY_PATH), str(capture)],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            verdict = json.loads(result.stdout)
            self.assertFalse(verdict['passed'])
            self.assertIn('worker:observed-upstream-hint-availability', verdict['issues'])
            self.assertEqual(verdict['negativeControls'], [])

    def test_canvas_cli_is_invoked_with_its_actual_supported_contract(self):
        command = MODULE.verifier_command(Path("fixtures"), "verify.py", Path("capture.json"))
        self.assertEqual(command[1:], ["fixtures/verify.py", "capture.json"])
        self.assertEqual(MODULE.verifier_command(Path("fixtures"), "verify-webgl.py", Path("capture.json"))[-1], "--negative-controls")

    def test_success_exit_does_not_replace_a_verdict_or_negative_controls(self):
        self.assertFalse(MODULE.verdict_passes({"exitCode": 0}))
        self.assertFalse(MODULE.verdict_passes({"passed": False}))
        self.assertTrue(MODULE.verdict_passes({"passed": True, "negativeControls": [{"name": "broken-fixture", "rejected": True}]}, expected_controls=("broken-fixture",)))
        self.assertFalse(MODULE.verdict_passes({"passed": True, "negativeControls": [{"name": "broken-fixture", "rejected": False}]}))
        self.assertFalse(MODULE.verdict_passes({"status": "verified-scoped-platform-operations", "issues": ["failed"]}))

    def test_missing_empty_malformed_and_duplicate_control_evidence_is_not_pass(self):
        self.assertFalse(MODULE.verdict_passes({"passed": True}))
        for controls in ([], None, {}, 1, "pass", [True], [{}], [{"name": "n", "rejected": 1}],
                         [{"name": "n", "rejected": True}] * 2):
            with self.subTest(controls=controls):
                self.assertFalse(MODULE.verdict_passes({"passed": True, "negativeControls": controls}))

    def test_every_named_case_requires_all_its_controls_without_extras(self):
        for case, names in MODULE.EXPECTED_CONTROL_NAMES.items():
            with self.subTest(case=case):
                report = {"passed": True, "negativeControls": [{"name": n, "rejected": True} for n in names]}
                self.assertTrue(MODULE.verdict_passes(report, expected_controls=names))
                for index in range(len(names)):
                    bad = copy.deepcopy(report)
                    bad["negativeControls"].pop(index)
                    self.assertFalse(MODULE.verdict_passes(bad, expected_controls=names))
                report["negativeControls"].append({"name": "unknown-control", "rejected": True})
                self.assertFalse(MODULE.verdict_passes(report, expected_controls=names))
        for case, _, _, verifier, _, _ in MODULE.CASES:
            if case not in ("drawing", "webgpu-native", "platform-state", "voices", "webgpu-policy"):
                self.assertIn(case, MODULE.EXPECTED_CONTROL_NAMES)

    def test_drawing_controls_have_their_own_required_receipt(self):
        report = {"passed": True, "controls": {"positiveFixturePassed": True,
                  "behaviorNegativeControlsRejected": 6, "pngNegativeControlsRejected": 4,
                  "pngFilterColorPositiveControls": 10}}
        self.assertTrue(MODULE.verdict_passes(report, contract="drawing"))
        for key in report["controls"]:
            bad = copy.deepcopy(report)
            bad["controls"].pop(key)
            self.assertFalse(MODULE.verdict_passes(bad, contract="drawing"), key)
        report["controls"]["positiveFixturePassed"] = 1
        self.assertFalse(MODULE.verdict_passes(report, contract="drawing"))

    def test_independent_oracle_controls_are_bound_to_their_case(self):
        report = {"status": "verified-scoped-platform-operations", "issues": []}
        receipt = {"positiveControls": 2, "negativeControls": 20, "actualBrowser": False}
        self.assertTrue(MODULE.verdict_passes(report, contract="platform-state", control_receipt=receipt))
        self.assertFalse(MODULE.verdict_passes(report, contract="platform-state"))
        self.assertFalse(MODULE.verdict_passes(report, contract="webgpu-native", control_receipt=receipt))
        for key in receipt:
            bad = dict(receipt)
            bad.pop(key)
            self.assertFalse(MODULE.verdict_passes(report, contract="platform-state", control_receipt=bad), key)
        self.assertFalse(MODULE.verdict_passes(report, contract="unknown", control_receipt=receipt))

    def test_voice_timeout_is_inconclusive_without_qualifying_the_case(self):
        source = "a" * 64
        def observation(kind, availability, count):
            return {"sourceSHA256": source, "result": {"observation": kind, "availability": availability, "count": count}}
        for good in (observation("observed", "available", "0"), observation("observed", "available", "256"),
                     observation("unavailable", "unavailable", "unavailable")):
            verdict = MODULE.voices_verdict(good, source)
            self.assertTrue(MODULE.verdict_passes(verdict, contract="observation"))
        timeout = MODULE.voices_verdict(observation("timeout", "available", "unavailable"), source)
        self.assertEqual(timeout["status"], "inconclusive")
        self.assertTrue(timeout["captureValid"])
        self.assertFalse(timeout["passed"])
        self.assertFalse(MODULE.verdict_passes(dict(timeout, passed=True), contract="observation"))
        for count in (None, 1, True, "257", "-1", "1.0", "9" * 10000, "٢"):
            self.assertFalse(MODULE.voices_verdict(observation("observed", "available", count), source)["passed"])
        self.assertFalse(MODULE.voices_verdict({}, source)["passed"])
        self.assertFalse(MODULE.voices_verdict(observation("observed", "available", "1"), "b" * 64)["passed"])

    def test_independent_runtime_binding_rejects_missing_or_wrong_receipts(self):
        binding = {"runtimeVersion": "156.0.8078.12", "runtimeExecutableSHA256": "a" * 64,
                   "runtimeFrameworkSHA256": "b" * 64}
        good = {"runtimeVersion": binding["runtimeVersion"], "executableSHA256": "a" * 64,
                "runtimeFrameworkSHA256": "b" * 64, "headed": True, "cleanupVerified": True,
                "documentEvidence": {"loaded": True}}
        self.assertTrue(MODULE.capture_binding_matches(good, binding))
        for field in good:
            bad = copy.deepcopy(good)
            bad.pop(field)
            self.assertFalse(MODULE.capture_binding_matches(bad, binding), field)
        bad = dict(good, runtimeFrameworkSHA256="c" * 64)
        self.assertFalse(MODULE.capture_binding_matches(bad, binding))
        for document in (None, {}, dict(good, documentEvidence=None), dict(good, documentEvidence=[])):
            self.assertFalse(MODULE.capture_binding_matches(document, binding))

    def test_real_capture_requires_frame_processing_revocation_denial_and_cleanup(self):
        good = {"kind": "synthetic-media-capture", "errors": [], "cleanupVerified": True,
                "before": {"camera": "granted", "microphone": "granted"},
                "tracks": [{"kind": "video", "state": "live"}, {"kind": "audio", "state": "live"}],
                "frame": {"presented": True, "nonzeroColor": True, "width": 640, "height": 480},
                "audio": {"finite": True, "frames": 256, "channels": 1, "callbacks": 1},
                "revoked": {"camera": "denied", "microphone": "denied", "events": 2},
                "denied": {"rejected": True, "error": "NotAllowedError"}}
        verdict = MODULE.checked_media_verdict(good)
        self.assertTrue(verdict["passed"])
        self.assertEqual(len(verdict["negativeControls"]), 5)
        self.assertTrue(all(c["rejected"] for c in verdict["negativeControls"]))
        for key in good:
            bad = copy.deepcopy(good)
            bad.pop(key)
            self.assertFalse(MODULE.media_verdict(bad)["passed"], key)
        # Failed captures must produce FAIL, not crash the verifier itself.
        self.assertFalse(MODULE.checked_media_verdict({"errors": ["timeout"]})["passed"])

    def test_immutable_resume_inputs_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "binding.json"
            MODULE.write_once(target, {"input": "original"})
            MODULE.write_once(target, {"input": "original"})
            with self.assertRaises(ValueError):
                MODULE.write_once(target, {"input": "changed"})


if __name__ == "__main__":
    unittest.main()
