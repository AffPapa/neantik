import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("manager_plan", Path(__file__).resolve().parents[1] / "plan-manager-checks.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class ManagerCheckPlanTests(unittest.TestCase):
    def test_hosted_input_checker_keeps_privacy_snapshot_and_future_delivery_gates(self):
        result = MOD.plan(['scripts/verify-direct-hosted-download.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_release_input_snapshot',
            'scripts.tests.test_verify_direct_hosted_download_oss',
            'scripts.tests.test_verify_public_artifact_privacy']])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])
        self.assertIn('signing and public-byte gates', result['requiredAdditionalGates'][0])
        unknown = MOD.plan(['scripts/verify-direct-hosted-other.py'], [])
        self.assertEqual(unknown['swiftMode'], 'full')
        self.assertTrue(any('discover' in command for command in unknown['commands']))

    def test_speech_harness_selects_its_controls_and_preserves_native_gate(self):
        result = MOD.plan(sorted(MOD.SPEECH_HARNESSES), [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_runtime_speech']])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])
        self.assertIn('do not prove native delivery', result['requiredAdditionalGates'][0])
        unknown = MOD.plan(['scripts/runtime-speech/unreviewed.mjs'], [])
        self.assertEqual(unknown['swiftMode'], 'full')
        self.assertTrue(any('discover' in command for command in unknown['commands']))

    def test_webrtc_closed_map_selects_node_controls_without_rebuilding(self):
        result=MOD.plan(sorted(MOD.WEBRTC_HARNESSES), [])
        self.assertEqual(result['swiftMode'],'none')
        self.assertEqual(result['commands'], [['node','scripts/runtime-network/'+name]
            for name in sorted(MOD.WEBRTC_CONTROLS)])
        self.assertEqual(len(result['reasons']),9)
        self.assertFalse(result['releaseGate'])
        unknown=MOD.plan(['scripts/runtime-network/unreviewed-webrtc.mjs'],[])
        self.assertTrue(any('discover' in command for command in unknown['commands']))

    def test_common_evidence_preparation_has_bounded_tests_without_release_authority(self):
        result = MOD.plan(['scripts/prepare_runtime_common_evidence.py'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_prepare_runtime_common_evidence']])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])
        self.assertFalse(result['releaseSurface'])
        self.assertIn('preparation never qualifies', result['requiredAdditionalGates'][0])
        unknown = MOD.plan(['scripts/prepare_runtime_common_evidence_other.py'], [])
        self.assertTrue(any('discover' in command for command in unknown['commands']))

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
            'scripts.tests.test_controlled_dns_fixture', 'scripts.tests.test_manager_dns_fixture', 'scripts.tests.test_manager_tcp_fixture', 'scripts.tests.test_manager_webrtc_fixture', 'scripts.tests.test_shipping_manager_route_fixture']])
        self.assertEqual(result['status'], 'not-run')
        self.assertIn('owned network', result['requiredAdditionalGates'][0])
        unknown = MOD.plan(['scripts/runtime-network/new-unknown.py'], [])
        self.assertTrue(any('discover' in command for command in unknown['commands']))

    def test_reviewed_shared_swift_keeps_full_swift_and_python_dependency_union(self):
        result = MOD.plan(sorted(MOD.SHARED_SWIFT), ['MCPProfileManagementTests'])
        self.assertEqual(result['swiftMode'], 'full')
        self.assertEqual(result['commands'][0][-1], '--all')
        self.assertEqual(result['commands'][1], ['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_responsive_ui_contract',
            'scripts.tests.test_verify_built_runtime_script',
            'scripts.tests.test_verify_chromium_launch_flags',
            'scripts.tests.test_verify_direct_ui_localization',
            'scripts.tests.test_verify_mcp_documentation',
            'scripts.tests.test_verify_public_artifact_privacy',
            'scripts.tests.test_verify_redacted_support_bundle'])
        self.assertEqual(result['status'], 'not-run')
        self.assertFalse(result['releaseGate'])
        self.assertTrue(any('stdio' in gate for gate in result['requiredAdditionalGates']))

    def test_mcp_dependency_is_not_lost_to_feature_classification(self):
        result = MOD.plan(['Sources/NeAntik/MCPProfileManagement.swift'], ['MCPProfileManagementTests'])
        self.assertEqual(result['commands'][1][-1], 'scripts.tests.test_verify_mcp_documentation')
        self.assertEqual(result['swiftMode'], 'full')
        # Similar names are deliberately not added to the reviewed shared map.
        unknown = MOD.plan(['Sources/NeAntik/MCPOutputSchemasOther.swift'], [])
        self.assertEqual(unknown['swiftMode'], 'full')

    def test_editor_and_help_keep_full_swift_with_closed_python_readers(self):
        result = MOD.plan(['Sources/NeAntik/ProfileEditorView.swift',
                           'Sources/NeAntik/HelpContent.swift'], [])
        self.assertEqual(result['swiftMode'], 'full')
        self.assertEqual(result['commands'][1], ['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_responsive_ui_contract',
            'scripts.tests.test_verify_mcp_documentation',
            'scripts.tests.test_verify_public_artifact_privacy'])
        self.assertTrue(any('native lifecycle/UI' in gate for gate in result['requiredAdditionalGates']))
        self.assertFalse(result['releaseGate'])
        unknown = MOD.plan(['Sources/NeAntik/ProfileEditorOther.swift'], [])
        self.assertTrue(any('discover' in command for command in unknown['commands']))

    def test_new_network_source_keeps_wildcard_reader_and_network_gate(self):
        result = MOD.plan(['Sources/NeAntik/ProxyProtocolDetector.swift'], ['ProxyProtocolDetectorTests'])
        self.assertEqual(result['swiftMode'], 'targeted')
        self.assertEqual(result['commands'][1], ['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_responsive_ui_contract'])
        self.assertTrue(any('controlled browser route' in gate for gate in result['requiredAdditionalGates']))
        self.assertFalse(result['releaseGate'])

    def test_semantic_docs_add_the_reader_without_swift_build(self):
        result = MOD.plan(['CHANGELOG.md', 'docs/MCP_GUIDE.md'], [])
        self.assertEqual(result['swiftMode'], 'none')
        self.assertEqual(result['commands'], [['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_verify_mcp_documentation']])

    def test_unknown_inputs_dominate_reviewed_selection(self):
        for path in ('Sources/NeAntik/UnreviewedShared.swift', 'Sources/NeAntik/Models.swift',
                     'Package.swift', '.github/workflows/unreviewed.yml',
                     'scripts/unreviewed.py', 'runtime/new-input.json'):
            with self.subTest(path=path):
                result = MOD.plan(['Sources/NeAntik/BrowserProcessManager.swift', path], [])
                self.assertEqual(result['swiftMode'], 'full')
                self.assertTrue(any('discover' in command for command in result['commands']))
                self.assertEqual(result['status'], 'not-run')
                self.assertFalse(result['releaseGate'])

    def test_swift_test_declarations_keep_python_inventory_contract(self):
        result = MOD.plan(['Tests/NeAntikTests/ExampleTests.swift'], ['ExampleTests'])
        self.assertEqual(result['selectedSuites'], ['ExampleTests'])
        self.assertEqual(result['commands'][1][-1], 'scripts.tests.test_verify_native_swift_tests_script')

    def test_info_path_alone_does_not_guess_version_only_change(self):
        result = MOD.plan(['Resources/Info.plist'], [])
        self.assertEqual(result['swiftMode'], 'full')
        self.assertTrue(any('discover' in command for command in result['commands']))
        self.assertFalse(MOD.version_only_info_change(None))
        narrowed = MOD.plan(['Resources/Info.plist'], [], version_only_info=True)
        self.assertEqual(narrowed['swiftMode'], 'full')
        self.assertEqual(narrowed['commands'][1], ['python3', '-B', '-m', 'unittest',
            'scripts.tests.test_verify_direct_version_bump',
            'scripts.tests.test_verify_mcp_documentation'])
        self.assertTrue(narrowed['releaseSurface'])
        self.assertFalse(narrowed['releaseGate'])

    def test_info_narrowing_uses_actual_baseline_and_rejects_policy_or_invalid_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL)
            git('init'); git('config', 'user.name', 'Owned fixture')
            git('config', 'user.email', 'qa@example.test')
            path = root / 'Resources/Info.plist'; path.parent.mkdir()
            original = dict(CFBundleShortVersionString='0.1.0', CFBundleVersion='1', Policy=False)
            path.write_bytes(plistlib.dumps(original)); git('add', '.'); git('commit', '-m', 'fixture')
            base = git('rev-parse', 'HEAD').decode().strip()
            self.assertFalse(MOD.version_only_info_change(base, root))
            changed = {**original, 'CFBundleShortVersionString': '0.1.1', 'CFBundleVersion': '2'}
            path.write_bytes(plistlib.dumps(changed))
            self.assertTrue(MOD.version_only_info_change(base, root))
            self.assertFalse(MOD.version_only_info_change('missing-baseline', root))
            for wrong in ({**changed, 'Policy': True}, {**changed, 'NewPolicy': False},
                          {**changed, 'CFBundleVersion': 2}):
                path.write_bytes(plistlib.dumps(wrong))
                self.assertFalse(MOD.version_only_info_change(base, root))
            path.write_bytes(b'<plist><broken')
            self.assertFalse(MOD.version_only_info_change(base, root))
            path.unlink(); path.symlink_to(root / 'missing')
            self.assertFalse(MOD.version_only_info_change(base, root))

    def test_rename_from_reviewed_to_unknown_keeps_both_paths_and_full_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL)
            git('init'); git('config', 'user.name', 'Owned fixture')
            git('config', 'user.email', 'qa@example.test')
            old = root / 'Sources/NeAntik/BrowserProcessManager.swift'; old.parent.mkdir(parents=True)
            old.write_text('fixture'); git('add', '.'); git('commit', '-m', 'fixture')
            git('mv', 'Sources/NeAntik/BrowserProcessManager.swift', 'Sources/NeAntik/NewUnknown.swift')
            _, paths = MOD.changed_paths('HEAD', root)
            self.assertEqual(len(paths), 2)
            result = MOD.plan(paths, [])
            self.assertEqual(result['swiftMode'], 'full')
            self.assertTrue(any('discover' in command for command in result['commands']))

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
            'scripts.tests.test_manager_dns_analysis','scripts.tests.test_manager_dns_custody','scripts.tests.test_manager_dns_fixture',
            'scripts.tests.test_manager_tcp_analysis','scripts.tests.test_manager_tcp_custody',
            'scripts.tests.test_manager_webrtc_analysis','scripts.tests.test_manager_webrtc_custody']])
        self.assertFalse(result['releaseGate']);self.assertEqual(result['status'],'not-run')

    def test_physical_tcp_has_its_source_and_analysis_controls(self):
        result=MOD.plan(['scripts/runtime-network/manager-tcp-fixture.py',
            'scripts/runtime-network/collect-manager-tcp.py','scripts/runtime-network/observe-manager-tcp-failure.py',
            'scripts/runtime-network/analyze-manager-tcp.py'],[])
        self.assertEqual(result['swiftMode'],'none')
        self.assertEqual(result['commands'],[['python3','-B','-m','unittest',
            'scripts.tests.test_manager_tcp_analysis','scripts.tests.test_manager_tcp_custody','scripts.tests.test_manager_tcp_fixture']])
        self.assertFalse(result['releaseGate']);self.assertEqual(result['status'],'not-run')

    def test_manager_webrtc_uses_its_distinct_fixture_custody_and_analysis(self):
        result=MOD.plan(['scripts/runtime-network/manager-webrtc-fixture.py',
            'scripts/runtime-network/manager-webrtc-probe.js','scripts/runtime-network/collect-manager-webrtc.py',
            'scripts/runtime-network/analyze-manager-webrtc.py'],[])
        self.assertEqual(result['swiftMode'],'none')
        self.assertEqual(result['commands'],[['python3','-B','-m','unittest',
            'scripts.tests.test_manager_webrtc_analysis','scripts.tests.test_manager_webrtc_custody','scripts.tests.test_manager_webrtc_fixture']])
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
