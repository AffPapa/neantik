import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-browser-identity-issuance.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_browser_identity_issuance",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

PROJECT_ROOT = Path(__file__).resolve().parents[2]


class BrowserIdentityIssuanceVerifierTests(unittest.TestCase):
    def test_current_policy_matches_swift_and_catalog(self) -> None:
        report = MODULE.verify(
            policy_path=PROJECT_ROOT
            / "runtime"
            / "browser-identity-issuance.json",
            catalog_path=PROJECT_ROOT
            / "runtime"
            / "apple-device-tuples.json",
            swift_path=PROJECT_ROOT
            / "Sources"
            / "NeAntik"
            / "Models.swift",
        )

        self.assertTrue(report["consistent"])
        self.assertEqual(report["candidateCount"], 780_903_144)
        self.assertEqual(report["membersPerCohort"], 195_225_786)
        self.assertEqual(len(report["allowedTupleIDs"]), 4)
        self.assertEqual(report["issues"], [])

    def test_rejects_small_enumerable_pool_or_wrong_selection(self) -> None:
        policy = json.loads(
            (
                PROJECT_ROOT
                / "runtime"
                / "browser-identity-issuance.json"
            ).read_text(encoding="utf-8")
        )
        policy["selection"] = "public-4096-seed-pool"
        policy["candidateCount"] = 4_096
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.IdentityIssuanceError,
                "selection",
            ):
                MODULE.load_policy(path)

    def test_rejects_unknown_or_duplicate_manifest_keys(self) -> None:
        source = (
            PROJECT_ROOT / "runtime" / "browser-identity-issuance.json"
        ).read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            unknown = Path(temporary) / "unknown.json"
            payload = json.loads(source)
            payload["unreviewed"] = True
            unknown.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.IdentityIssuanceError,
                "keys",
            ):
                MODULE.load_policy(unknown)

            duplicate = Path(temporary) / "duplicate.json"
            duplicate.write_text(
                source.replace(
                    '"schemaVersion": 1,',
                    '"schemaVersion": 99, "schemaVersion": 1,',
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.IdentityIssuanceError,
                "duplicate JSON key",
            ):
                MODULE.load_policy(duplicate)

    def test_detects_swift_residue_drift(self) -> None:
        source = (
            PROJECT_ROOT / "Sources" / "NeAntik" / "Models.swift"
        ).read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "Models.swift"
            path.write_text(
                source.replace(
                    "[0, 2, 5, 8]",
                    "[0, 2, 5, 7]",
                    1,
                ),
                encoding="utf-8",
            )
            report = MODULE.verify(
                policy_path=PROJECT_ROOT
                / "runtime"
                / "browser-identity-issuance.json",
                catalog_path=PROJECT_ROOT
                / "runtime"
                / "apple-device-tuples.json",
                swift_path=path,
            )

        self.assertFalse(report["consistent"])
        self.assertTrue(
            any("commonTupleResidues" in issue for issue in report["issues"])
        )

    def test_swift_comments_cannot_mask_constant_drift(self) -> None:
        source = (
            PROJECT_ROOT / "Sources" / "NeAntik" / "Models.swift"
        ).read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "Models.swift"
            path.write_text(
                source.replace(
                    "static let currentVersion = 2",
                    "static let currentVersion = 3\n"
                    "    // static let currentVersion = 2",
                    1,
                ),
                encoding="utf-8",
            )
            report = MODULE.verify(
                policy_path=PROJECT_ROOT
                / "runtime"
                / "browser-identity-issuance.json",
                catalog_path=PROJECT_ROOT
                / "runtime"
                / "apple-device-tuples.json",
                swift_path=path,
            )

        self.assertFalse(report["consistent"])
        self.assertTrue(
            any("currentVersion" in issue for issue in report["issues"])
        )

    def test_detects_profile_repair_policy_drift(self) -> None:
        source = (
            PROJECT_ROOT / "scripts" / "repair-profile-metadata.py"
        ).read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "repair.py"
            path.write_text(
                source.replace(
                    "CURRENT_ISSUANCE_RESIDUES = {0, 2, 5, 8}",
                    "CURRENT_ISSUANCE_RESIDUES = {0, 2, 5, 7}",
                    1,
                ),
                encoding="utf-8",
            )
            report = MODULE.verify(
                policy_path=PROJECT_ROOT
                / "runtime"
                / "browser-identity-issuance.json",
                catalog_path=PROJECT_ROOT
                / "runtime"
                / "apple-device-tuples.json",
                swift_path=PROJECT_ROOT
                / "Sources"
                / "NeAntik"
                / "Models.swift",
                repair_path=path,
            )

        self.assertFalse(report["consistent"])
        self.assertTrue(
            any("CURRENT_ISSUANCE_RESIDUES" in issue for issue in report["issues"])
        )

    def test_rejects_manifest_tuple_residue_mismatch(self) -> None:
        policy = json.loads(
            (
                PROJECT_ROOT
                / "runtime"
                / "browser-identity-issuance.json"
            ).read_text(encoding="utf-8")
        )
        policy["allowedTupleIDs"][0] = "macbook-pro-m1-pro"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            report = MODULE.verify(
                policy_path=path,
                catalog_path=PROJECT_ROOT
                / "runtime"
                / "apple-device-tuples.json",
                swift_path=PROJECT_ROOT
                / "Sources"
                / "NeAntik"
                / "Models.swift",
            )

        self.assertFalse(report["consistent"])
        self.assertTrue(
            any("tuple residue" in issue for issue in report["issues"])
        )


if __name__ == "__main__":
    unittest.main()
