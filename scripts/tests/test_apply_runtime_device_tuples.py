from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import unittest


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "apply-runtime-device-tuples.py"
)
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
