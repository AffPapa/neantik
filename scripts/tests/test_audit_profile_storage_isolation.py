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
