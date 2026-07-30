import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "repair-profile-metadata.py"
SPEC = importlib.util.spec_from_file_location("repair_profile_metadata", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RepairProfileMetadataTests(unittest.TestCase):
    def test_repairs_real_legacy_unsigned_seeds(self) -> None:
        profiles = [
            {"name": "Legacy A", "identity": {"seed": 2_456_110_098}},
            {"name": "Legacy B", "identity": {"seed": 3_454_592_789}},
        ]
        repaired, changes = MODULE.repair_profiles(profiles)
        self.assertEqual(
            [profile["identity"]["seed"] for profile in repaired],
            [308_626_450, 1_307_109_141],
        )
        self.assertEqual(len(changes), 2)

    def test_preserves_unique_runtime_safe_seed(self) -> None:
        profiles = [{"name": "Safe", "identity": {"seed": 123}}]
        repaired, changes = MODULE.repair_profiles(profiles)
        self.assertEqual(repaired, profiles)
        self.assertEqual(changes, [])

    def test_repairs_collisions_without_touching_browser_fields(self) -> None:
        profiles = [
            {"id": "first", "name": "A", "identity": {"seed": 1}, "startURL": "https://example.com"},
            {"id": "second", "name": "B", "identity": {"seed": 2_147_483_649}, "startURL": "https://example.org"},
        ]
        repaired, changes = MODULE.repair_profiles(profiles)
        self.assertEqual(repaired[0]["identity"]["seed"], 1)
        self.assertEqual(repaired[1]["identity"]["seed"], 12)
        self.assertEqual(repaired[1]["startURL"], "https://example.org")
        self.assertEqual(len(changes), 1)

    def test_current_issuance_collision_preserves_reviewed_tuple(self) -> None:
        profiles = [
            {
                "name": "A",
                "identity": {"seed": 123, "issuanceVersion": 2},
            },
            {
                "name": "B",
                "identity": {"seed": 123, "issuanceVersion": 2},
            },
        ]
        repaired, changes = MODULE.repair_profiles(profiles)
        self.assertEqual(repaired[0]["identity"]["seed"], 123)
        self.assertEqual(repaired[1]["identity"]["seed"], 134)
        self.assertEqual(
            repaired[0]["identity"]["seed"] % 11,
            repaired[1]["identity"]["seed"] % 11,
        )
        self.assertEqual(
            repaired[1]["identity"]["issuanceVersion"],
            2,
        )
        self.assertEqual(len(changes), 1)

    def test_rejects_unknown_or_out_of_policy_current_issuance(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported"):
            MODULE.repair_profiles(
                [{"identity": {"seed": 123, "issuanceVersion": 99}}]
            )
        with self.assertRaisesRegex(ValueError, "outside issuance policy"):
            MODULE.repair_profiles(
                [{"identity": {"seed": 42, "issuanceVersion": 2}}]
            )
        with self.assertRaisesRegex(ValueError, "outside issuance policy"):
            MODULE.repair_profiles(
                [
                    {
                        "identity": {
                            "seed": 2_147_483_650,
                            "issuanceVersion": 2,
                        }
                    }
                ]
            )

    def test_boolean_metadata_does_not_pass_as_an_integer(self) -> None:
        repaired, changes = MODULE.repair_profiles(
            [{"name": "Boolean seed", "identity": {"seed": True}}]
        )
        self.assertIs(type(repaired[0]["identity"]["seed"]), int)
        self.assertEqual(repaired[0]["identity"]["seed"], 1)
        self.assertEqual(changes, ["Boolean seed: seed True -> 1"])

        with self.assertRaisesRegex(ValueError, "invalid issuanceVersion"):
            MODULE.repair_profiles(
                [{"identity": {"seed": 123, "issuanceVersion": True}}]
            )

    def test_apply_writes_backup_and_private_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profiles.json"
            path.write_text(
                json.dumps([{"name": "Legacy", "identity": {"seed": 2_456_110_098}}]),
                encoding="utf-8",
            )
            repaired, changes = MODULE.repair_profiles(MODULE.load_profiles(path))
            backup = MODULE.apply_repairs(path, repaired)
            self.assertTrue(backup.exists())
            self.assertEqual(changes, ["Legacy: seed 2456110098 -> 308626450"])
            self.assertEqual(
                MODULE.load_profiles(path)[0]["identity"]["seed"],
                308_626_450,
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
