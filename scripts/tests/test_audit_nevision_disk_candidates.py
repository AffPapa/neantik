import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "audit-nevision-disk-candidates.py"
SPEC = importlib.util.spec_from_file_location("audit_nevision_disk_candidates", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class NeAntikDiskCandidateAuditTests(unittest.TestCase):
    def test_classifies_preserved_evidence_root_as_protected(self) -> None:
        preserved = Path("/private/tmp/nevision-chromium-build-20260725")
        classification, reason = MODULE.classify(
            preserved,
            preserved_evidence_root=preserved,
        )
        self.assertEqual(classification, "protected")
        self.assertIn("evidence", reason)

    def test_classifies_roundtrip_and_extracted_as_safe_disposable(self) -> None:
        preserved = Path("/private/tmp/nevision-chromium-build-20260725")
        for name in [
            "nevision-integrated-extracted.abc",
            "nevision-035-roundtrip.abc",
            "nevision-telemetry-node_modules-partial-20260725",
        ]:
            classification, _ = MODULE.classify(
                Path("/private/tmp") / name,
                preserved_evidence_root=preserved,
            )
            self.assertEqual(classification, "safe-disposable")

    def test_classifies_toolchain_dmg_as_requires_approval(self) -> None:
        classification, reason = MODULE.classify(
            Path("/private/tmp/nevision-metaltoolchain-17C7003j.dmg"),
            preserved_evidence_root=Path("/private/tmp/nevision-chromium-build-20260725"),
        )
        self.assertEqual(classification, "requires-approval")
        self.assertIn("toolchain", reason)

    def test_scan_is_read_only_and_applies_minimum_size(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            small = root / "nevision-small-extracted"
            small.mkdir()
            (small / "tiny.txt").write_text("x", encoding="utf-8")
            large = root / "nevision-final-verify-demo"
            large.mkdir()
            (large / "blob.bin").write_bytes(b"x" * 2048)
            candidates = MODULE.scan(
                [root],
                preserved_evidence_root=root / "nevision-chromium-build-20260725",
                minimum_mib=0,
            )
        paths = {Path(candidate.path).name for candidate in candidates}
        self.assertIn("nevision-small-extracted", paths)
        self.assertIn("nevision-final-verify-demo", paths)

    def test_summary_reports_totals_by_classification(self) -> None:
        candidates = [
            MODULE.DiskCandidate("/tmp/a", 1024 * 1024, 1, "safe-disposable", "x"),
            MODULE.DiskCandidate("/tmp/b", 2 * 1024 * 1024, 2, "protected", "x"),
        ]
        summary = MODULE.summarize(candidates)
        self.assertEqual(summary["totalsMiB"]["safe-disposable"], 1)
        self.assertEqual(summary["totalsMiB"]["protected"], 2)

    def test_root_free_space_reports_existing_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            free = MODULE.root_free_space([root])
        self.assertIn(str(root), free)
        self.assertGreaterEqual(free[str(root)], 0)

    def test_rebase_readiness_reports_deficit_after_safe_disposable(self) -> None:
        readiness = MODULE.rebase_readiness(
            free_gib_by_root={"/private/tmp": 12},
            totals_mib={"safe-disposable": 7 * 1024, "protected": 25 * 1024},
            required_free_gib=55,
        )
        root = readiness["roots"]["/private/tmp"]
        self.assertEqual(root["afterSafeDisposableGiB"], 19)
        self.assertEqual(root["deficitAfterSafeDisposableGiB"], 36)
        self.assertFalse(root["passesAfterSafeDisposable"])

    def test_rebase_readiness_passes_when_safe_disposable_is_enough(self) -> None:
        readiness = MODULE.rebase_readiness(
            free_gib_by_root={"/Volumes/Build": 48},
            totals_mib={"safe-disposable": 8 * 1024},
            required_free_gib=55,
        )
        root = readiness["roots"]["/Volumes/Build"]
        self.assertEqual(root["afterSafeDisposableGiB"], 56)
        self.assertEqual(root["deficitAfterSafeDisposableGiB"], 0)
        self.assertTrue(root["passesAfterSafeDisposable"])


if __name__ == "__main__":
    unittest.main()
