import hashlib
import importlib.util
import json
import sys
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "apply-owned-runtime-device-tuples.py"
SPEC = importlib.util.spec_from_file_location(
    "apply_owned_runtime_device_tuples",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ApplyOwnedRuntimeDeviceTuplesTests(unittest.TestCase):
    def test_generated_header_contains_every_canonical_tuple(self) -> None:
        tuples = MODULE.CATALOG_LOADER.load_device_tuples(
            MODULE.CATALOG_PATH
        )
        header = MODULE.render_header(tuples)

        self.assertEqual(len(tuples), 11)
        self.assertEqual(header.count('    {"macbook-'), 11)
        for tuple_ in tuples:
            self.assertIn(f'"{tuple_.id}"', header)
            self.assertIn(f'"{tuple_.gpu_model}"', header)
            self.assertIn(f'"{tuple_.platform_version}"', header)
        self.assertIn("seed % kAppleDeviceTupleCount", header)
        self.assertIn("physical_memory_gb", header)
        self.assertIn("web_device_memory_gb", header)
        self.assertEqual(
            hashlib.sha256(header.encode("utf-8")).hexdigest(),
            MODULE.POSTIMAGE_SHA256[MODULE.HEADER_PATH],
        )

    def test_every_generated_postimage_is_locked_by_patch_manifest(self) -> None:
        manifest = json.loads(
            (
                PROJECT_ROOT
                / "runtime"
                / "nevision-patches"
                / "series.json"
            ).read_text(encoding="utf-8")
        )
        generated = manifest["generatedInputs"]

        self.assertEqual(len(generated), 1)
        self.assertEqual(
            generated[0]["postimageSHA256"],
            MODULE.POSTIMAGE_SHA256,
        )
        self.assertEqual(
            generated[0]["catalogSHA256"],
            hashlib.sha256(MODULE.CATALOG_PATH.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            generated[0]["generatorSHA256"],
            hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
        )

    def test_owned_transform_covers_all_tuple_consumers(self) -> None:
        self.assertEqual(
            set(MODULE.TRANSFORMS),
            set(MODULE.PREIMAGE_SHA256),
        )
        self.assertEqual(
            set(MODULE.POSTIMAGE_SHA256),
            {MODULE.HEADER_PATH, *MODULE.TRANSFORMS},
        )
        self.assertTrue(
            all(
                len(digest) == 64
                and set(digest) <= set("0123456789abcdef")
                for digest in MODULE.POSTIMAGE_SHA256.values()
            )
        )


if __name__ == "__main__":
    unittest.main()
