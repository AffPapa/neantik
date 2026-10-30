import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release_comparison", Path(__file__).resolve().parents[1] / "compare-release-reports.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


def record(version="0.8.11", build=122):
    return dict(version=version, build=build, sourceCommit="a" * 40,
        managerSHA256="b" * 64,
        runtime=dict(chromiumVersion="156.0.8078.12", architecture="arm64",
                     executableSHA256="c" * 64, frameworkSHA256="d" * 64),
        changes=["Public source change"], limitations=["Public alpha"],
        verification=dict(downloadedHeaded="freshenrollment/headed/drainPASS", nativeUpdater=dict(passed=True)))


def context():
    return dict(osVersion="27.0", architecture="arm64", headed=True,
        memoryPressure=0, thermalState=0, environmentSHA256="e" * 64,
        harnessSHA256="f" * 64, fixtureSHA256="1" * 64,
        profileConfigurationSHA256="2" * 64)


class ReleaseReportComparisonTests(unittest.TestCase):
    def test_current_published_records_are_read_without_inventing_behavior(self):
        report = MOD.build_version_comparison('0.8.22', '0.8.23')
        self.assertEqual(report['after']['runtime']['architecture'], 'arm64')
        self.assertEqual(report['qualificationDeclaration'], {'before': True, 'after': True})
        self.assertEqual(report['behaviorRegressionVerdict'], 'not_established')
        self.assertEqual(report['performanceComparison'], 'not_measured')
        self.assertFalse(report['measurementComparability']['declaredContextsMatch'])
        for item in report['verification']:
            if item['key'] in ('site', 'downloadedHeaded', 'nativeRollback'):
                self.assertNotEqual(item['after']['state'], 'reported_pass')
        self.assertIn('NOT PASS', report['testDeclarations']['after']['Python'])
        self.assertIn('Aggregate failures retained', report['testDeclarations']['after']['Swift'])
        self.assertTrue(report['localizedChanges'])
        self.assertTrue(report['localizedLimitations'])

    def test_latest_snapshot_cannot_hide_open_delivery_or_source_failures(self):
        report = MOD.build_version_comparison('0.8.22', '0.8.23')
        root = MOD.ROOT / 'docs/evidence'
        stored = json.loads((root / 'regression-0.8.22-0.8.23.json').read_text())
        rendered = (root / 'regression-0.8.22-0.8.23.md').read_text()
        MOD.require_matching_snapshot(report, stored, rendered)
        broken = copy.deepcopy(stored)
        gate = next(x for x in broken['verification'] if x['key'] == 'site')
        gate['after']['state'] = 'reported_pass'
        with self.assertRaises(MOD.ReportError): MOD.require_matching_snapshot(report, broken, rendered)
        broken = copy.deepcopy(stored); broken['testDeclarations']['after']['Python'] = 'PASS all'
        with self.assertRaises(MOD.ReportError): MOD.require_matching_snapshot(report, broken, rendered)

    def test_top_level_architecture_cannot_conceal_conflicting_runtime(self):
        source = record(); source['architecture'] = 'x86_64'
        with self.assertRaises(MOD.ReportError): MOD.identity(source)

    def test_checks_projection_does_not_promote_unrelated_or_unknown_evidence(self):
        source = dict(checks={'exactHeaded': 'PASS local', 'updaterNative': 'PASS commit and rollback',
                              'sourceSwift': '17 with skips', 'sourcePython': 'NOT PASS',
                              'unknownSecret': 'private marker'},
                      signing={'notarization': 'Accepted', 'stapling': 'PASS', 'gatekeeper': 'PASS',
                               'unknownSecret': 'private marker'}, releaseQualified=True)
        result = MOD.verification_fields(source)
        self.assertEqual(result['GUIFingerprint'], 'PASS local')
        self.assertEqual(result['nativeUpdater'], 'PASS commit and rollback')
        self.assertNotIn('downloadedHeaded', result)
        self.assertNotIn('nativeRollback', result)
        self.assertNotIn('private marker', json.dumps(result))
        self.assertEqual(result['tests'], {'Swift': '17 with skips', 'Python': 'NOT PASS'})
        self.assertTrue(result['releaseQualified'])
        # A malformed legacy field cannot be silently replaced by newer PASS.
        for bad in [None, [], True, 'PASS']:
            value = copy.deepcopy(source); value['verification'] = bad
            with self.assertRaises(MOD.ReportError): MOD.verification_fields(value)
            value = copy.deepcopy(source); value['checks'] = bad
            with self.assertRaises(MOD.ReportError): MOD.verification_fields(value)
            value = copy.deepcopy(source); value['signing'] = bad
            with self.assertRaises(MOD.ReportError): MOD.verification_fields(value)
        legacy = {'verification': {'site': 'OPEN: legacy'}, **source}
        self.assertEqual(MOD.verification_fields(legacy), legacy['verification'])

    def test_checked_snapshots_match_current_public_sources_and_text(self):
        expected = MOD.build_version_comparison('0.8.11', '0.8.12')
        root = MOD.ROOT / 'docs/evidence'
        stored = json.loads((root / 'regression-0.8.11-0.8.12.json').read_text())
        rendered = (root / 'regression-0.8.11-0.8.12.md').read_text()
        MOD.require_matching_snapshot(expected, stored, rendered)
        broken = copy.deepcopy(stored)
        broken['behaviorRegressionVerdict'] = 'no_regressions'
        with self.assertRaises(MOD.ReportError): MOD.require_matching_snapshot(expected, broken, rendered)
        wrong_type = copy.deepcopy(stored)
        wrong_type['noBrowserLaunched'] = 1
        with self.assertRaises(MOD.ReportError): MOD.require_matching_snapshot(expected, wrong_type, rendered)
        wrong_number = copy.deepcopy(stored)
        wrong_number['after']['build'] = float(wrong_number['after']['build'])
        with self.assertRaises(MOD.ReportError): MOD.require_matching_snapshot(expected, wrong_number, rendered)
        with self.assertRaises(MOD.ReportError): MOD.require_matching_snapshot(expected, stored, rendered + 'Invented claim\n')

    def test_malformed_test_summary_is_refused_and_mixed_failure_text_is_preserved(self):
        for value in (None, [], "private fixture", {"Swift": True}):
            b = record("0.8.12", 124)
            b['verification']['tests'] = value
            with self.assertRaises(MOD.ReportError): MOD.compare(record(), b)
        b = record("0.8.12", 124)
        text = 'full run failed; affected12 PASS; original not allgreen'
        b['verification']['tests'] = {'Python': text, 'unknownSecret': 'private fixture'}
        result = MOD.compare(record(), b)
        self.assertEqual(result['testDeclarations']['after']['Python'], text)
        self.assertNotIn('private fixture', json.dumps(result))

    def test_identical_executables_do_not_prove_behavior_or_complete_inventory(self):
        result = MOD.compare(record(), record("0.8.12", 124))
        self.assertTrue(result["identityComparison"]["runtimeExecutableDigestsEqual"])
        self.assertFalse(result["identityComparison"]["fullRuntimeInventoryCompared"])
        self.assertEqual(result["behaviorRegressionVerdict"], "not_established")
        self.assertEqual(result["performanceComparison"], "not_measured")
        self.assertFalse(result["measurementComparability"]["declaredContextsMatch"])

    def test_complete_matching_context_does_not_manufacture_a_runtime_pass(self):
        a, b = record(), record("0.8.12", 124)
        a["measurementContext"] = context()
        b["measurementContext"] = context()
        result = MOD.compare(a, b)
        self.assertTrue(result["measurementComparability"]["declaredContextsMatch"])
        self.assertFalse(result["measurementComparability"]["independentlyVerified"])
        self.assertEqual(result["behaviorRegressionVerdict"], "not_established")

    def test_each_changed_condition_prevents_comparability(self):
        for key in MOD.CONTEXT_KEYS:
            with self.subTest(key=key):
                a, b = record(), record("0.8.12", 124)
                a["measurementContext"], b["measurementContext"] = context(), context()
                b["measurementContext"][key] = {"osVersion": "27.1", "architecture": "x86_64",
                    "headed": False, "memoryPressure": 2, "thermalState": 1}.get(key, "3" * 64)
                if key == "architecture":
                    b["runtime"][key] = "x86_64"
                result = MOD.compare(a, b)["measurementComparability"]
                self.assertFalse(result["declaredContextsMatch"])
                self.assertEqual(result["reason"], "different_context")
                self.assertIn(key, result["differingFields"])

    def test_missing_or_invalid_context_never_defaults_to_matching(self):
        for key in MOD.CONTEXT_KEYS:
            a, b = record(), record("0.8.12", 124)
            a["measurementContext"], b["measurementContext"] = context(), context()
            del b["measurementContext"][key]
            self.assertEqual(MOD.compare(a, b)["measurementComparability"]["reason"], "missing_context")
        for key, value in (("headed", 1), ("memoryPressure", True), ("thermalState", 4),
                           ("osVersion", "private environment text"), ("harnessSHA256", "bad")):
            a, b = record(), record("0.8.12", 124)
            a["measurementContext"], b["measurementContext"] = context(), context()
            b["measurementContext"][key] = value
            self.assertFalse(MOD.compare(a, b)["measurementComparability"]["declaredContextsMatch"])

    def test_open_or_mixed_declaration_cannot_become_pass_by_substring(self):
        for text in ("OPEN: localPASS but not deployed", "full failed; later PASS", "original not allgreen; affectedPASS",
                     "no PASS", "not PASS", "without PASS", "unavailable PASS", "not all green; PASS"):
            self.assertNotEqual(MOD.declared_gate(text)["state"], "reported_pass")
        self.assertEqual(MOD.declared_gate("anonymousSHA/sizeMATCH")["state"], "reported_match")

    def test_false_boolean_and_missing_evidence_remain_distinct(self):
        self.assertEqual(MOD.declared_gate(dict(passed=False))["state"], "reported_fail")
        self.assertEqual(MOD.declared_gate(None)["state"], "unknown")
        self.assertEqual(MOD.declared_gate(dict(passed="true"))["state"], "unknown")

    def test_leading_pass_cannot_hide_later_failure_or_unexecuted_gate(self):
        declarations = [
            'PASS local; downloaded FAIL', 'PASS locally; hosted ERROR',
            'PASS local; downloaded failed', 'PASS local; hosted pending',
            'PASS local; remaining blocked', 'PASS source; native not-run',
            'PASS source; native not executed', 'PASS source; native skipped',
            'PASS local; qualification incomplete', 'PASS local; remote timeout',
            'PASS local; partial hosted validation',
            'PASS local; 2FAIL', 'PASS local; 1FAILED',
            'PASS local; 3ERRORS', 'PASS local; 2SKIP', 'PASS4FAIL',
        ]
        for text in declarations:
            with self.subTest(text=text):
                result = MOD.declared_gate(text)
                self.assertNotEqual(result['state'], 'reported_pass')
                self.assertEqual(result['declaration'], text)
                a, b = record(), record('0.8.12', 124)
                b['verification']['downloadedHeaded'] = text
                comparison = MOD.compare(a, b)
                gate = next(x for x in comparison['verification'] if x['key'] == 'downloadedHeaded')
                self.assertNotEqual(gate['after']['state'], 'reported_pass')
                row = next(x for x in MOD.markdown(comparison).splitlines()
                           if x.startswith('| Запуск скачанной копии |'))
                self.assertFalse(row.endswith('| заявлен PASS |'))
        # Failover is a policy, not an observed failure. Do not fix this by
        # rejecting every string that merely contains the letters "fail".
        self.assertEqual(MOD.declared_gate('PASS with failover disabled')['state'], 'reported_pass')
        self.assertEqual(MOD.declared_gate('13/13PASS')['state'], 'reported_pass')
        self.assertEqual(MOD.declared_gate('PASS 0FAIL 0ERROR')['state'], 'reported_pass')

    def test_site_legacy_alias_and_current_open_gate_compare_without_false_green(self):
        a, b = record(), record("0.8.12", 124)
        a["verification"]["liveSite"] = "anonymousrelease/homePASS"
        b["verification"]["site"] = "37sourcePASS; saved149; not deployed"
        site = next(x for x in MOD.compare(a, b)["verification"] if x["key"] == "site")
        self.assertEqual(site["before"]["state"], "reported_pass")
        self.assertEqual(site["after"]["state"], "open")

    def test_unknown_sensitive_fields_are_not_copied(self):
        a, b = record(), record("0.8.12", 124)
        b["privateUnknown"] = "private fixture data"
        b["verification"]["unknownSecret"] = "private fixture data"
        a["measurementContext"], b["measurementContext"] = context(), context()
        b["measurementContext"]["rawICE"] = "private fixture data"
        self.assertNotIn("private fixture data", json.dumps(MOD.compare(a, b)))

    def test_new_manager_and_runtime_digests_are_reported_as_changes(self):
        a, b = record(), record("0.8.12", 124)
        b["managerSHA256"] = "4" * 64
        b["runtime"]["frameworkSHA256"] = "5" * 64
        result = MOD.compare(a, b)["identityComparison"]
        self.assertTrue(result["managerExecutableChanged"])
        self.assertFalse(result["runtimeExecutableDigestsEqual"])

    def test_invalid_or_reused_version_build_and_identity_are_rejected(self):
        for key, value in (("version", "../../private"), ("build", True), ("sourceCommit", "short"), ("managerSHA256", "bad")):
            a, b = record(), record("0.8.12", 124)
            b[key] = value
            with self.assertRaises(MOD.ReportError): MOD.compare(a, b)
        for version, build in (("0.8.11", 124), ("0.8.10", 124), ("0.8.12", 122)):
            with self.assertRaises(MOD.ReportError): MOD.compare(record(), record(version, build))

    def test_duplicate_json_and_symlink_input_are_rejected(self):
        with self.assertRaises(MOD.ReportError): MOD.reject_duplicates([("build", 1), ("build", 2)])
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "releases").mkdir()
            target = root / "public.json"
            target.write_text(json.dumps(record()))
            (root / "releases/v0.8.11.json").symlink_to(target)
            with patch.object(MOD, "ROOT", root):
                with self.assertRaises(MOD.ReportError): MOD.load_version("0.8.11")

    def test_markdown_is_explicit_about_missing_measurements(self):
        text = MOD.markdown(MOD.compare(record(), record("0.8.12", 124)))
        self.assertIn("не хватает сведений", text)
        self.assertIn("не установлен", text)
        self.assertIn("не измерялась", text)
        self.assertIn("Полный инвентарь runtime здесь не сравнивается", text)

    def test_actual_public_records_and_cli_retain_declared_facts_without_behavior_verdict(self):
        a, _ = MOD.load_version("0.8.11")
        b, _ = MOD.load_version("0.8.12")
        result = MOD.compare(a, b)
        self.assertTrue(result["identityComparison"]["runtimeExecutableDigestsEqual"])
        self.assertEqual(result["after"]["version"], "0.8.12")
        self.assertEqual(result["qualificationDeclaration"]["after"], b["verification"].get("releaseQualified"))
        cli = subprocess.run([sys.executable, "-B", str(Path(MOD.__file__)), "--before", "0.8.11", "--after", "0.8.12"], capture_output=True, text=True, check=True)
        actual = json.loads(cli.stdout)
        self.assertEqual(actual["behaviorRegressionVerdict"], "not_established")
        self.assertTrue(actual["localizedChanges"])
        self.assertIn("sourceRecordSHA256", actual)
        self.assertNotEqual(actual["after"]["sourceCommit"], actual["before"]["sourceCommit"])

    def test_cli_refuses_paths_and_does_not_emit_private_input(self):
        result = subprocess.run([sys.executable, "-B", str(Path(MOD.__file__)), "--before", "../../private-fixture", "--after", "0.8.12"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("private-fixture", result.stdout + result.stderr)
