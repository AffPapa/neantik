import hashlib
import importlib.util
import sys
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "apply-owned-runtime-device-tuples-153.py"
SPEC = importlib.util.spec_from_file_location(
    "apply_owned_runtime_device_tuples_153",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ApplyOwnedRuntimeDeviceTuples153Tests(unittest.TestCase):
    def test_patch_sha_and_postimages_are_locked(self) -> None:
        digest = hashlib.sha256(MODULE.PATCH_PATH.read_bytes()).hexdigest()
        self.assertEqual(digest, MODULE.EXPECTED_PATCH_SHA256)
        self.assertEqual(len(MODULE.POSTIMAGE_SHA256), 8)
        self.assertTrue(
            all(
                len(value) == 64
                and set(value) <= set("0123456789abcdef")
                for value in MODULE.POSTIMAGE_SHA256.values()
            )
        )

    def test_patch_is_153_specific(self) -> None:
        text = MODULE.PATCH_PATH.read_text(encoding="utf-8")
        self.assertIn("neantik_apple_device_tuples.h", text)
        self.assertIn("GetAppleDeviceTuple", text)
        self.assertNotIn('"apple-device-tuple"', text)


if __name__ == "__main__":
    unittest.main()
