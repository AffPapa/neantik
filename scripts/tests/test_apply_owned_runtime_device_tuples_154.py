import hashlib
import importlib.util
import sys
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "apply-owned-runtime-device-tuples-154.py"
SPEC = importlib.util.spec_from_file_location(
    "apply_owned_runtime_device_tuples_154_test", SCRIPT
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ApplyOwnedRuntimeDeviceTuples154Tests(unittest.TestCase):
    def test_m154_source_and_catalog_locks_are_pinned(self) -> None:
        self.assertEqual(MODULE.EXPECTED_CHROMIUM_VERSION, "154.0.8037.93")
        self.assertEqual(len(MODULE.EXPECTED_SOURCE_COMMIT), 40)
        self.assertEqual(len(MODULE.EXPECTED_SOURCE_TREE), 40)
        self.assertEqual(
            hashlib.sha256(MODULE.CATALOG_PATH.read_bytes()).hexdigest(),
            MODULE.EXPECTED_CATALOG_SHA256,
        )

    def test_m154_generated_postimage_set_is_complete_and_locked(self) -> None:
        renderer = MODULE.load_renderer()
        self.assertEqual(set(MODULE.PREIMAGE_SHA256), set(renderer.TRANSFORMS))
        self.assertEqual(
            set(MODULE.POSTIMAGE_SHA256),
            {renderer.HEADER_PATH, *renderer.TRANSFORMS},
        )
        self.assertTrue(
            all(len(value) == 64 for value in MODULE.PREIMAGE_SHA256.values())
        )
        self.assertTrue(
            all(len(value) == 64 for value in MODULE.POSTIMAGE_SHA256.values())
        )
        self.assertEqual(
            MODULE.POSTIMAGE_SHA256[
                "third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc"
            ],
            "ff4756e11005c719c4cfeaee06ad783a073d8b5a02b9290aba59879d184a26b7",
        )

    def test_m154_webgl_tuple_postimage_contains_safe_span_changes(self) -> None:
        renderer = MODULE.load_renderer()
        renderer.transform_webgl = lambda text: text
        source = '''#include "base/byte_size.h"
#include "base/compiler_specific.h"

              String::Format(
                  "ANGLE (Apple, ANGLE Metal Renderer: Apple %s, "
                  "Unspecified Version)",
                  tuple.gpu_model));

    const size_t sample_count = std::min<size_t>(pixel_count, 16);
      data[byte_index] = static_cast<uint8_t>(
          data[byte_index] >= 255 - delta ? data[byte_index] - delta
                                          : data[byte_index] + delta);
'''
        output = MODULE.transform_webgl_154(renderer, source)
        self.assertIn("StrCat({\"ANGLE (Apple, ANGLE Metal Renderer: Apple ", output)
        self.assertIn('#include "base/containers/span.h"', output)
        self.assertIn("pixels->ByteSpanMaybeShared().subspan", output)
        self.assertIn("output[byte_index] >= 255 - delta", output)
        self.assertNotIn("data[byte_index]", output)

    def test_generated_header_uses_all_canonical_tuple_rows(self) -> None:
        renderer = MODULE.load_renderer()
        tuples = renderer.CATALOG_LOADER.load_device_tuples(
            renderer.CATALOG_PATH
        )
        header = renderer.render_header(tuples)
        self.assertEqual(len(tuples), 11)
        self.assertEqual(header.count('    {"macbook-'), 11)
        self.assertIn("seed % kAppleDeviceTupleCount", header)
        swift = (PROJECT_ROOT / "Sources/NeAntik/FingerprintAudit.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "Int(seed % UInt32(appleDeviceTuples.count))",
            swift,
        )
        self.assertEqual(
            hashlib.sha256(header.encode("utf-8")).hexdigest(),
            MODULE.POSTIMAGE_SHA256[renderer.HEADER_PATH],
        )


if __name__ == "__main__":
    unittest.main()
