import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "export-chromium-150-build-root-readiness.py"
SPEC = importlib.util.spec_from_file_location("export_chromium_150_build_root_readiness", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write_project(root: Path) -> None:
    (root / "runtime").mkdir()
    (root / "runtime" / "chromium-150-rebase-plan.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "targetChromiumVersion": "150.0.7871.186",
                "minimumPrepareFreeGiB": 55,
                "preservedEvidenceBuildRoot": str(root / "old-144"),
                "macPackaging": {
                    "repository": "https://github.com/ungoogled-software/ungoogled-chromium-macos.git",
                    "commit": "9cbd94c2b8f6f2a58a80bf32b3e01b68f3d129d4",
                    "packagedChromiumVersion": "150.0.7871.181",
                },
                "commonChromium": {
                    "repository": "https://github.com/ungoogled-software/ungoogled-chromium.git",
                    "tag": "150.0.7871.186-1",
                    "commit": "fd0378e4f20fa09e21b09beca71573d435d787cf",
                },
            }
        ),
        encoding="utf-8",
    )
    (root / "runtime" / "security-baseline.json").write_text(
        json.dumps({"schemaVersion": 1, "minimumPublicChromiumVersion": "150.0.7871.186"}),
        encoding="utf-8",
    )


def write_cleanup_plan(root: Path, *, current: int, reclaim: int) -> Path:
    path = root / "dist" / "NeAntik-disk-cleanup-plan-latest.json"
    path.parent.mkdir()
    path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "approval": {
                    "required": True,
                    "executeCommand": "NEANTIK_DISK_CLEANUP_APPROVAL=TOKEN scripts/export-nevision-disk-cleanup-plan.py --execute --plan dist/NeAntik-disk-cleanup-plan-latest.json",
                },
                "rebaseReadiness": {
                    "requiredFreeGiB": 55,
                    "safeDisposableReclaimGiB": reclaim,
                    "roots": {
                        "/private/tmp": {
                            "currentFreeGiB": current,
                            "afterSafeDisposableGiB": current + reclaim,
                            "deficitAfterSafeDisposableGiB": max(0, 55 - current - reclaim),
                            "passesAfterSafeDisposable": current + reclaim >= 55,
                        }
                    },
                },
            }
        ),
        encoding="utf-8",
    )
    return path


class Chromium150BuildRootReadinessTests(unittest.TestCase):
    def test_reports_ready_candidate_with_free_space_override(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            build_root = root / "build-150"
            report = MODULE.build_readiness(
                project_root=root,
                candidate_roots=[build_root],
                free_gib=80,
                generated_at="2026-07-26T00:00:00+00:00",
            )

        self.assertTrue(report["summary"]["hasReadyBuildRoot"])
        self.assertEqual(report["summary"]["recommendedBuildRoot"], str(build_root))
        self.assertEqual(report["candidates"][0]["status"], "ready-for-source-pair-bootstrap")
        self.assertIn("bootstrapCommand", report["candidates"][0])

    def test_reports_blocked_candidate_without_throwing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            cleanup_plan = write_cleanup_plan(root, current=12, reclaim=7)
            report = MODULE.build_readiness(
                project_root=root,
                candidate_roots=[root / "build-150"],
                free_gib=12,
                disk_cleanup_plan=cleanup_plan,
            )

        self.assertFalse(report["summary"]["hasReadyBuildRoot"])
        self.assertFalse(report["summary"]["safeDisposableCleanupCanSatisfyLocalBuildRoot"])
        self.assertTrue(report["summary"]["localBuildRootRequiresExternalVolumeOrOwnerDecision"])
        self.assertEqual(
            report["ownerDecisionContract"]["status"],
            "owner-storage-decision-required",
        )
        self.assertEqual(report["ownerDecisionContract"]["requiredFreeGiB"], 55)
        self.assertIn(
            "/Volumes/NeAntikBuild",
            report["ownerDecisionContract"]["recommendedExternalVolume"],
        )
        template = report["ownerBuildRootInputTemplate"]
        self.assertEqual(template["target"], "owner-shell-environment")
        self.assertEqual(template["placeholdersMustBeReplaced"], MODULE.OWNER_BUILD_ROOT_PLACEHOLDERS)
        self.assertEqual(
            template["defaultRecommendedValue"],
            report["ownerDecisionContract"]["recommendedExternalBuildRoot"],
        )
        self.assertIn("NEANTIK_CHROMIUM_150_BUILD_ROOT", "\n".join(template["requiredEnvironment"]))
        self.assertTrue(any("Do not delete" in item for item in template["safetyBoundary"]))
        self.assertIn(
            "Do not delete",
            "\n".join(report["ownerDecisionContract"]["prohibitedActions"]),
        )
        self.assertEqual(report["cleanupProjection"]["afterSafeDisposableGiB"], 19)
        self.assertEqual(report["cleanupProjection"]["deficitAfterSafeDisposableGiB"], 36)
        self.assertFalse(report["candidates"][0]["ready"])
        self.assertIn("55 GiB", report["candidates"][0]["error"])

    def test_reports_safe_cleanup_projection_when_it_would_be_enough(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            cleanup_plan = write_cleanup_plan(root, current=40, reclaim=20)
            report = MODULE.build_readiness(
                project_root=root,
                candidate_roots=[root / "build-150"],
                free_gib=40,
                disk_cleanup_plan=cleanup_plan,
            )

        self.assertFalse(report["summary"]["hasReadyBuildRoot"])
        self.assertTrue(report["summary"]["safeDisposableCleanupCanSatisfyLocalBuildRoot"])
        self.assertFalse(report["summary"]["localBuildRootRequiresExternalVolumeOrOwnerDecision"])
        self.assertEqual(report["cleanupProjection"]["afterSafeDisposableGiB"], 60)

    def test_reports_missing_external_volume_as_not_mounted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            report = MODULE.build_readiness(
                project_root=root,
                candidate_roots=[Path("/Volumes/NeAntikDefinitelyMissing/nevision-chromium-150")],
                free_gib=80,
            )

        self.assertFalse(report["summary"]["hasReadyBuildRoot"])
        self.assertEqual(report["candidates"][0]["status"], "not-mounted")
        self.assertIn("/Volumes/NeAntikDefinitelyMissing", report["candidates"][0]["error"])

    def test_markdown_is_public_safe_and_read_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_project(root)
            report = MODULE.build_readiness(
                project_root=root,
                candidate_roots=[root / "build-150"],
                free_gib=12,
                disk_cleanup_plan=None,
            )
            markdown = MODULE.format_markdown(report)

        self.assertIn("read-only", markdown)
        self.assertIn("Ready candidates", markdown)
        self.assertIn("Cleanup projection", markdown)
        self.assertIn("Owner storage decision contract", markdown)
        self.assertIn("Commands after owner storage is ready", markdown)
        self.assertIn("Owner build-root input template", markdown)
        self.assertIn("<ABSOLUTE_CHROMIUM_150_BUILD_ROOT>", markdown)
        self.assertIn("Prohibited actions", markdown)
        self.assertNotIn("rm -rf", markdown)


if __name__ == "__main__":
    unittest.main()
