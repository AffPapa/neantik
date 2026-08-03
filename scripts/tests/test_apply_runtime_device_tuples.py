from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import re
import tempfile
import unittest


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "apply-runtime-device-tuples.py"
)
PROJECT_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "apply_runtime_device_tuples",
    SCRIPT_PATH,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ApplyRuntimeDeviceTuplesTests(unittest.TestCase):
    def test_catalog_rows_are_coherent_and_cover_each_gpu(self) -> None:
        rows = re.findall(
            r"\{(\d+), (\d+), (\d+), ([\d.]+)f, "
            r"(\d+), (\d+), (\d+), (\d+), ([\d.]+), "
            r'"([\d.]+)"\}',
            MODULE.TUPLE_CATALOG,
        )

        self.assertEqual(len(rows), 11)
        self.assertEqual([int(row[0]) for row in rows], list(range(11)))
        for row in rows:
            physical_memory = int(row[2])
            exposed_memory = float(row[3])
            screen_width = int(row[4])
            screen_height = int(row[5])
            available_width = int(row[6])
            available_height = int(row[7])
            scale = float(row[8])

            self.assertGreaterEqual(physical_memory, exposed_memory)
            self.assertEqual(available_width, screen_width)
            self.assertLessEqual(available_height, screen_height)
            self.assertEqual(scale, 2.0)

    def test_generated_catalog_is_exact_manifest_projection(self) -> None:
        tuples = MODULE.load_device_tuples(
            PROJECT_ROOT / "runtime" / "apple-device-tuples.json"
        )

        self.assertEqual(MODULE.render_tuple_catalog(tuples), MODULE.TUPLE_CATALOG)
        self.assertEqual(
            hashlib.sha256(MODULE.TUPLE_CATALOG.encode("utf-8")).hexdigest(),
            MODULE.EXPECTED_GENERATED_CATALOG_SHA256,
        )
        self.assertEqual(
            [item.id for item in tuples],
            [
                "macbook-air-m1",
                "macbook-pro-m1-pro",
                "macbook-air-m2",
                "macbook-pro-m2-max",
                "macbook-pro-m2-pro",
                "macbook-air-m3",
                "macbook-pro-m3-max",
                "macbook-pro-m3-pro",
                "macbook-air-m4",
                "macbook-pro-m4-max",
                "macbook-pro-m4-pro",
            ],
        )

    def test_catalog_rejects_scale_or_field_drift(self) -> None:
        payload = json.loads(
            (
                PROJECT_ROOT / "runtime" / "apple-device-tuples.json"
            ).read_text(encoding="utf-8")
        )
        payload["tuples"][0]["deviceScaleFactor"] = 1
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "tuples.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.DeviceTupleCatalogError,
                "deviceScaleFactor disagrees",
            ):
                MODULE.load_device_tuples(path)

        payload["tuples"][0]["deviceScaleFactor"] = 2
        payload["tuples"][0]["unexpected"] = "drift"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "tuples.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.DeviceTupleCatalogError,
                "fields drifted",
            ):
                MODULE.load_device_tuples(path)

    def test_every_overlay_has_locked_preimage_and_postimage(self) -> None:
        for relative, expectation in MODULE.FILES.items():
            with self.subTest(relative=relative):
                self.assertRegex(expectation["before"], r"^[0-9a-f]{64}$")
                self.assertRegex(expectation["after"], r"^[0-9a-f]{64}$")
                self.assertIn(
                    expectation["transform"],
                    MODULE.TRANSFORMS,
                )

    def test_client_hints_version_is_not_selected_by_profile_seed(self) -> None:
        source = """
    return kMacOSVersions[seed % std::size(kMacOSVersions)];
  // 3. Check if has fingerprint seed
  if (command_line->HasSwitch(switches::kFingerprint)) {
    int seed = 0;
    base::StringToInt(
        command_line->GetSwitchValueASCII(switches::kFingerprint), &seed);
    return kChromiumVersions[seed % std::size(kChromiumVersions)];
  }

  // 4. Return first version
  return kChromiumVersions[0];
"""
        transformed = MODULE.transform_user_agent(source)

        self.assertNotIn(
            "kChromiumVersions[seed %",
            transformed,
        )
        self.assertIn(
            "GetMacOSDeviceTuple(static_cast<uint32_t>(seed))",
            transformed,
        )
        self.assertIn(
            "exact compiled Chromium version",
            transformed,
        )


if __name__ == "__main__":
    unittest.main()
