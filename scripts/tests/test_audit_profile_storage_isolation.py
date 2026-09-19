import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "audit-profile-storage-isolation.py"
SPEC = importlib.util.spec_from_file_location(
    "audit_profile_storage_isolation",
    SCRIPT_PATH,
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ProfileStorageIsolationAuditTests(unittest.TestCase):
    def test_rejects_pending_script_only_duplicate_and_incomplete_results(self):
        valid = '<pre id="result">NV_RESULT:{"cookie":"x","storage":"x"}</pre>'
        for output in (
            '<pre id="result">pending</pre>',
            '<script>const sample = \'NV_RESULT:{"cookie":"x","storage":"x"}\';</script>',
            valid + valid,
            '<pre id="result">NV_RESULT:{"cookie":"x"}</pre>',
            '<pre id="result">NV_RESULT:invalid</pre>',
        ):
            with self.subTest(output=output), self.assertRaises(MODULE.IsolationAuditError):
                MODULE.parse_dumped_result(output)

    def test_browser_mode_preserves_sandbox_and_multiprocess(self):
        for name in ("NeAntik Browser", "Chromium"):
            args = MODULE.capture_arguments(Path('/fixture') / name, Path('/temporary/Profile A'), 'http://127.0.0.1/')
            self.assertIn('--headless=new', args)
            self.assertNotIn('--no-sandbox', args)
            self.assertNotIn('--single-process', args)
            self.assertIn('--user-data-dir=/temporary/Profile A', args)

    def test_legacy_shell_mode_is_explicit_and_unknown_binary_rejected(self):
        self.assertEqual(MODULE.runtime_mode(Path('/fixture/headless_shell')), 'headless-single-process-storage-diagnostic')
        with self.assertRaises(MODULE.IsolationAuditError):
            MODULE.runtime_mode(Path('/fixture/unrelated-program'))

    def test_parses_dumped_browser_result(self):
        result = MODULE.parse_dumped_result(
            '<pre id="result">NV_RESULT:'
            '{"cookie":"A-value","storage":"A-value"}</pre>'
        )
        self.assertEqual(
            result,
            {"cookie": "A-value", "storage": "A-value"},
        )

    def test_accepts_persistent_isolated_sequence(self):
        token_a = "A-value"
        token_b = "B-value"
        captures = {
            "aSet": {"cookie": token_a, "storage": token_a},
            "aRead1": {"cookie": token_a, "storage": token_a},
            "bReadEmpty": {"cookie": "", "storage": ""},
            "bSet": {"cookie": token_b, "storage": token_b},
            "aRead2": {"cookie": token_a, "storage": token_a},
            "bRead": {"cookie": token_b, "storage": token_b},
        }
        self.assertEqual(
            MODULE.verify_sequence(captures, token_a, token_b),
            [],
        )

    def test_detects_cross_profile_cookie_or_storage_leak(self):
        token_a = "A-value"
        token_b = "B-value"
        captures = {
            "aSet": {"cookie": token_a, "storage": token_a},
            "aRead1": {"cookie": token_a, "storage": token_a},
            "bReadEmpty": {"cookie": token_a, "storage": ""},
            "bSet": {"cookie": token_b, "storage": token_b},
            "aRead2": {"cookie": token_a, "storage": token_a},
            "bRead": {"cookie": token_b, "storage": token_b},
        }
        issues = MODULE.verify_sequence(captures, token_a, token_b)
        self.assertEqual(len(issues), 1)
        self.assertIn("bReadEmpty", issues[0])


if __name__ == "__main__":
    unittest.main()
