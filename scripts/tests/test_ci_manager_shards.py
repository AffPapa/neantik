import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
import io

SPEC = importlib.util.spec_from_file_location("ci_manager", Path(__file__).resolve().parents[1] / "test-manager-ci.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class CIManagerShardTests(unittest.TestCase):
    def test_webkit_proxy_experiment_is_opt_in_and_pure_endpoint_controls_stay_in_ci(self):
        root = Path(__file__).resolve().parents[2]
        fixtures = json.loads((root / 'scripts/swift-runtime-fixture-suites.json').read_text())
        self.assertEqual(set(fixtures['WebKitProxyNonLoopbackQualificationTests']), {
            'NEANTIK_WEBKIT_PROXY_NONLOOPBACK_QUALIFICATION',
            'NEANTIK_WEBKIT_PROXY_NONLOOPBACK_WARNING_ONCE',
            'NEANTIK_WEBKIT_PROXY_NONLOOPBACK_MATCH_MODE',
            'NEANTIK_WEBKIT_PROXY_NONLOOPBACK_FRONTEND'})
        suites = MOD.catalog()
        self.assertNotIn('WebKitProxyNonLoopbackQualificationTests', suites)
        self.assertNotIn('WebKitProxySOCKSQualificationTests', suites)
        self.assertIn('WebKitProxyOwnedEndpointTests', suites)
        self.assertIn('WebKitProxySOCKSCodecTests', suites)
        self.assertNotIn('NEANTIK_WEBKIT_PROXY_NONLOOPBACK_QUALIFICATION',
                         MOD.clean_environment({'NEANTIK_WEBKIT_PROXY_NONLOOPBACK_QUALIFICATION': '1'}))

    def test_pure_native_fixtures_are_excluded_but_mixed_security_suites_remain(self):
        suites = MOD.catalog()
        for name in ['WebKitCacheLiveTests', 'WebKitCacheOwnedCleanupTests',
                     'WebKitSessionLifecycleTests', 'ProxyTesterLiveFixtureTests',
                     'WebKitDeletionLiveTests']:
            self.assertNotIn(name, suites)
        for name in ['WebKitCacheMaintenanceTests', 'ProxyRelayLoopbackServerTests',
                     'ProxyRelayTLSQualificationTests', 'ProxyRelaySocketOwnerInspectorTests',
                     'PlatformLaunchReceiptTests']:
            self.assertIn(name, suites)

    def test_deletion_fixture_has_only_explicit_phase_gates(self):
        root = Path(__file__).resolve().parents[2]
        fixtures = json.loads((root / 'scripts/swift-runtime-fixture-suites.json').read_text())
        self.assertEqual(set(fixtures['WebKitDeletionLiveTests']),
            {'NEANTIK_WEBKIT_DELETE_PHASE', 'NEANTIK_WEBKIT_DELETE_ROOT', 'NEANTIK_WEBKIT_DELETE_ORIGIN'})
        source = (root / 'Tests/NeAntikTests/WebKitDeletionLiveTests.swift').read_text()
        # Every operation is opt-in headed QA; none is an ordinary unit test.
        self.assertEqual(source.count('@Test('), 3)
        self.assertEqual(source.count('@Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_DELETE_PHASE"]'), 3)
        self.assertNotIn('WebKitDeletionLiveTests', MOD.catalog())

    def test_failure_diagnostics_are_bounded_redacted_and_actionable(self):
        synthetic_home_path = str(Path('/').joinpath('Users', 'example', 'file'))
        text = 'ordinary secret text\nfile.swift:4: error: missing API\nerror: token=ghp_ABC123 password="private value" http://u:p@host/ 203.0.113.8 ' + synthetic_home_path + '\n'
        lines = MOD.failure_diagnostics(text + ''.join(f'error: extra {i}\n' for i in range(40)))
        self.assertEqual(len(lines), 20)
        self.assertIn('missing API', lines[0])
        self.assertNotIn('ghp_ABC123', '\n'.join(lines))
        self.assertNotIn('private value', '\n'.join(lines))
        self.assertNotIn('u:p@', '\n'.join(lines))
        self.assertNotIn('203.0.113.8', '\n'.join(lines))
        self.assertNotIn('ordinary secret text', '\n'.join(lines))
        self.assertLessEqual(max(map(len, lines)), 512)

    def test_diagnostic_suite_is_exact_and_ordinary(self):
        with patch.object(MOD.sys, 'argv', ['ci', '--suite', 'AppPathsTests', '--plan']), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(MOD.main(), 0)
            self.assertEqual(json.loads(output.getvalue())['suites'], ['AppPathsTests'])
        for suite in ['.*', 'UnknownTests', 'LiveProxyTests']:
            with self.subTest(suite=suite), patch.object(MOD.sys, 'argv', ['ci', '--suite', suite, '--plan']), redirect_stdout(io.StringIO()), patch.object(MOD.sys, 'stderr', io.StringIO()):
                with self.assertRaises(SystemExit): MOD.main()
    def test_ci_removes_mixed_suite_and_presence_based_local_qa_overrides(self):
        env = {"PATH": "/bin", "LANG": "en_US.UTF-8", "NEANTIK_WEBKIT_LIVE": "1",
               "NEANTIK_RELAY_PUBLIC_TLS_FIXTURE": "1", "NEANTIK_UPDATE_TEST_ROOT": "/private/tmp/owned-qa",
               "NEANTIK_POPULATE_DEV_FIXTURE": "/private/tmp/owned-qa"}
        self.assertEqual(MOD.clean_environment(env), {"PATH": "/bin", "LANG": "en_US.UTF-8"})

    def test_failed_empty_or_changed_source_stops_before_next_suite(self):
        warning = ("warning: '--build-system native' has been deprecated and will be removed "
                   "in a future release; please report an issue at "
                   "https://github.com/swiftlang/swift-package-manager/issues if you are "
                   "unable to adopt the default build system.\n")
        interrupted = ("✔ Test works() passed after 0.1 seconds.\n"
                       "✔ Test run with 1 test in 1 suite" + warning + " passed\n").encode()
        for exit_code, output, changed in [(1, b"failed", False), (1, interrupted, False),
                                          (0, b"Test run with 0 tests in 0 suites passed", False),
                                          (0, "➜ Test requiresHardware() skipped: unavailable\n✔ Test run with 1 test in 1 suite passed".encode(), False),
                                          (0, "✔ Test works() passed after 0.1 seconds.\n✔ Test run with 1 test in 1 suite passed".encode(), True)]:
            with self.subTest(exit_code=exit_code, changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); calls = []
                def fake(command, **kwargs):
                    calls.append(command); kwargs['stdout'].write(output); return exit_code
                with patch.object(MOD, 'ROOT', root), patch.object(MOD, 'catalog', return_value=['FirstTests', 'SecondTests']), patch.object(MOD.sys, 'argv', ['ci', '--shard', '0', '--shards', '1']), patch.object(MOD.subprocess, 'check_output', return_value='/owned-toolchain'), patch.object(MOD.fast, 'supervise', side_effect=fake), patch.object(MOD.fast, 'input_digest', side_effect=['before', 'after' if changed else 'before']), redirect_stdout(io.StringIO()):
                    self.assertEqual(MOD.main(), 1)
                report = json.loads((root / '.build/neantik-ci/0/receipts/summary.json').read_text())
                self.assertEqual(len(calls), 1)
                self.assertNotEqual(report['status'], 'pass')
                self.assertEqual(report['results'][0]['suite'], 'FirstTests')

    def test_every_non_live_suite_runs_exactly_once_across_shards(self):
        suites = MOD.catalog()
        shards = [MOD.partition(suites, i, 4) for i in range(4)]
        union = [s for shard in shards for s in shard]
        self.assertEqual(sorted(union), suites)
        self.assertEqual(len(union), len(set(union)))
        self.assertLessEqual(max(map(len, shards)) - min(map(len, shards)), 1)

    def test_bad_or_empty_shard_is_not_an_empty_pass(self):
        for index, count in [(-1, 4), (4, 4), (0, 0), (0, 5)]:
            with self.assertRaises(ValueError): MOD.partition(["A", "B", "C", "D"], index, count)

    def test_new_suite_is_included_and_live_or_fixture_suite_is_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "Tests/NeAntikTests"; tests.mkdir(parents=True)
            scripts = root / "scripts"; scripts.mkdir()
            for suite in ["NewFeatureTests", "LiveOwnedTests", "HeadedFixtureTests"]:
                (tests / (suite + ".swift")).write_text("@Suite struct " + suite + " {}")
            (scripts / "swift-runtime-fixture-suites.json").write_text(json.dumps({"HeadedFixtureTests": ["NEANTIK_OWNED_FIXTURE"]}))
            self.assertEqual(MOD.catalog(root), ["NewFeatureTests"])
            (scripts / "swift-runtime-fixture-suites.json").write_text('{"MissingTests": ["NEANTIK_OWNED_FIXTURE"]}')
            with self.assertRaises(ValueError): MOD.catalog(root)

    def test_nested_suite_is_discovered_and_unscoped_test_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); tests = root / 'Tests/NeAntikTests/Nested'; tests.mkdir(parents=True)
            scripts = root / 'scripts'; scripts.mkdir(); (scripts/'swift-runtime-fixture-suites.json').write_text('{}')
            (tests/'ActorTests.swift').write_text('@Suite actor NestedActorTests { @Test func works() {} }')
            self.assertEqual(MOD.catalog(root), ['NestedActorTests'])
            (tests/'TopLevel.swift').write_text('@Test func unscoped() {}')
            with self.assertRaises(ValueError): MOD.catalog(root)
