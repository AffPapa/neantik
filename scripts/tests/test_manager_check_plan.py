import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("manager_plan", Path(__file__).resolve().parents[1] / "plan-manager-checks.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class ManagerCheckPlanTests(unittest.TestCase):
    def test_offline_dns_transition_and_planner_have_explicit_bounded_contracts(self):
        result = MOD.plan(['scripts/runtime-network/manager-dns-transition.py',
                           'scripts/plan-manager-checks.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3','-B','-m','unittest',
            'scripts.tests.test_manager_check_plan','scripts.tests.test_manager_dns_analysis']])
        self.assertFalse(result['releaseGate'])

    def test_report_comparison_uses_related_controls_without_new_app_release(self):
        result = MOD.plan(['scripts/compare-release-reports.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_compare_release_reports']])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])
        self.assertIn('matching measurement conditions', result['requiredAdditionalGates'][0])

    def test_readiness_observer_needs_its_controls_and_real_observation_not_an_app_build(self):
        result = MOD.plan(['scripts/native-qa-readiness.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_native_qa_readiness']])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])
        self.assertIn('real read-only macOS', result['requiredAdditionalGates'][0])

    def test_document_only_does_not_rebuild_but_is_not_a_pass(self):
        plan = MOD.plan(["docs/DEVELOPMENT_WORKFLOW.md"], ["WebKitProfileTests"])
        self.assertEqual(plan["swiftMode"], "none")
        self.assertEqual(plan["status"], "not-run")
        self.assertTrue(plan["requiredAdditionalGates"])

    def test_signed_artifact_is_not_misclassified_as_release_documentation(self):
        for path in ['releases/v0.8.2/NeAntik.zip', 'dist/NeAntik.dmg', 'dist/NeAntik.app/Contents/MacOS/NeAntik']:
            plan = MOD.plan([path], ['WebKitProfileTests'])
            self.assertEqual(plan['reasons'][0]['surface'], 'release-delivery')
            self.assertTrue(plan['releaseSurface'])
            self.assertFalse(plan['releaseGate'])
            self.assertTrue(any('Gatekeeper' in g for g in plan['requiredAdditionalGates']))

    def test_unknown_or_shared_inputs_require_full_regression(self):
        for path in ["Sources/NeAntik/NewFeature.swift", "Sources/NeAntik/BrowserProfile.swift", "Package.swift", "Resources/Info.plist", "Tests/Fixtures/Helper.swift"]:
            plan = MOD.plan([path], ["WebKitProfileTests"])
            self.assertEqual(plan["swiftMode"], "full", path)
            self.assertIn("--all", plan["commands"][0])

    def test_reviewed_standalone_fixture_has_targeted_controls_only(self):
        result = MOD.plan(['scripts/runtime-network/manager-route-fixture.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_controlled_dns_fixture', 'scripts.tests.test_manager_dns_fixture', 'scripts.tests.test_shipping_manager_route_fixture']])
        self.assertEqual(result['status'], 'not-run')
        self.assertIn('owned network', result['requiredAdditionalGates'][0])
        unknown = MOD.plan(['scripts/runtime-network/new-unknown.py'], [])
        self.assertIn('discover', unknown['commands'][0])

    def test_dns_fixture_has_bounded_controls_but_no_browser_pass_or_build(self):
        result = MOD.plan(['scripts/runtime-network/controlled-dns-fixture.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_controlled_dns_fixture', 'scripts.tests.test_manager_dns_fixture']])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])

    def test_manager_dns_harnesses_select_custody_and_sensitivity_without_app_build(self):
        result=MOD.plan(['scripts/runtime-network/manager-dns-fixture.py',
            'scripts/runtime-network/collect-manager-dns.py','scripts/runtime-network/analyze-manager-dns.py'],[])
        self.assertEqual(result['swiftMode'],'none')
        self.assertEqual(result['commands'],[['python3','-B','-m','unittest',
            'scripts.tests.test_manager_dns_analysis','scripts.tests.test_manager_dns_custody','scripts.tests.test_manager_dns_fixture']])
        self.assertFalse(result['releaseGate']);self.assertEqual(result['status'],'not-run')

    def test_route_observer_selects_background_and_existing_route_controls(self):
        result = MOD.plan(['scripts/controlled-browser-route-observer.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_background_netlog_observer', 'scripts.tests.test_controlled_browser_route_observer']])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])

    def test_known_surface_and_its_dependency_suites_are_batched(self):
        plan = MOD.plan(["Sources/NeAntik/WebKitProfileBrowser.swift"], ["WebKitProfileTests", "MCPProfileManagementTests", "UnrelatedTests"])
        self.assertEqual(plan["selectedSuites"], ["MCPProfileManagementTests", "WebKitProfileTests"])
        self.assertEqual(plan["swiftMode"], "targeted")
        self.assertTrue(any("headed" in g for g in plan["requiredAdditionalGates"]))

    def test_missing_or_deleted_suite_never_yields_empty_targeted_success(self):
        self.assertEqual(MOD.plan(["Tests/NeAntikTests/RemovedTests.swift"], [])['swiftMode'], "full")
        self.assertEqual(MOD.plan(["Sources/NeAntik/WebKitProfileBrowser.swift"], [])['swiftMode'], "full")

    def test_absolute_traversal_or_secrets_path_is_refused(self):
        for path in ["/absolute/path", "../../data", ".secrets/token", ""]:
            with self.assertRaises(ValueError): MOD.plan([path], [])

    def test_git_collects_staged_unstaged_untracked_and_both_rename_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args): return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL)
            git("init"); git("config", "user.name", "Owned fixture"); git("config", "user.email", "qa@example.test")
            for name in ["first.md", "second.md", "old.md"]: (root/name).write_text("before")
            git("add", "."); git("commit", "-m", "fixture")
            (root/"first.md").write_text("staged"); git("add", "first.md")
            (root/"second.md").write_text("unstaged"); (root/"new.md").write_text("new")
            git("mv", "old.md", "renamed.md")
            _, paths = MOD.changed_paths("HEAD", root)
            self.assertEqual(paths, ["first.md", "new.md", "old.md", "renamed.md", "second.md"])
