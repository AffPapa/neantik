import copy
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-nevision-patchset-manifest.py"
SPEC = importlib.util.spec_from_file_location("verify_nevision_patchset_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class NeAntikPatchsetManifestTests(unittest.TestCase):
    def test_current_manifest_is_valid_port_plan(self) -> None:
        summary = MODULE.verify_manifest(
            manifest_path=PROJECT_ROOT / "runtime" / "nevision-patches" / "series.json",
            rebase_plan_path=PROJECT_ROOT / "runtime" / "chromium-150-rebase-plan.json",
            release=False,
            verify_source_evidence=True,
            project_root=PROJECT_ROOT,
        )

        self.assertEqual(summary["targetChromiumVersion"], "150.0.7871.186")
        self.assertIn(
            summary["manifestStatus"],
            {"planned-not-ported", "partially-ported", "release-ready"},
        )
        if summary["manifestStatus"] == "release-ready":
            self.assertEqual(summary["plannedCount"], 0)
            self.assertTrue(summary["releaseReady"])
        else:
            self.assertGreater(summary["plannedCount"], 0)
            self.assertFalse(summary["releaseReady"])
        self.assertGreaterEqual(summary["portedCount"], 0)
        self.assertEqual(summary["groupCount"], len(summary["groups"]))
        self.assertTrue(
            all(
                group["status"] in {"planned", "ported"}
                and isinstance(group["sourceEvidenceCount"], int)
                and isinstance(group["requiredBehaviorCount"], int)
                for group in summary["groups"]
            )
        )

    def test_source_evidence_mode_rejects_missing_owner_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["patchGroups"][0]["sourceEvidence"] = ["missing-owner-file.swift"]
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "sourceEvidence is missing"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                    verify_source_evidence=True,
                    project_root=root,
                )

    def test_release_mode_blocks_planned_groups(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path, rebase_path = write_fixture(root)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "not release-ready"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=True,
                )

    def test_rejects_target_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["targetChromiumVersion"] = "151.0.1.2"
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "must match"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_manifest_status_that_does_not_match_group_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["status"] = "release-ready"
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "status must be"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_manifest_without_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            del manifest["policy"]
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "policy"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_duplicate_forbidden_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["forbiddenScopes"] = ["automation-evasion", "automation-evasion"]
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "unique"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_ported_group_without_patch_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["patchGroups"][0]["status"] = "ported"
            manifest["patchGroups"][0]["patchFile"] = "missing.patch"
            manifest["patchGroups"][0]["postimageSHA256"] = {"a.cc": "a" * 64}
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "missing.patch"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_ported_group_with_patch_digest_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            patch = "patches/stable-surface.patch"
            manifest["patchGroups"][0]["status"] = "ported"
            manifest["patchGroups"][0]["patchFile"] = patch
            manifest["patchGroups"][0]["patchSHA256"] = "0" * 64
            manifest["patchGroups"][0]["postimageSHA256"] = {"a.txt": "a" * 64}
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)
            patch_path = manifest_path.parent / patch
            patch_path.parent.mkdir(parents=True)
            patch_path.write_text("diff --git a/a.txt b/a.txt\n", encoding="utf-8")

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "patchSHA256 mismatch"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_ported_group_with_unsafe_patch_file_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["patchGroups"][0]["status"] = "ported"
            manifest["patchGroups"][0]["patchFile"] = "../outside.patch"
            manifest["patchGroups"][0]["patchSHA256"] = "a" * 64
            manifest["patchGroups"][0]["postimageSHA256"] = {"a.txt": "a" * 64}
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "patchFile"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_planned_group_with_patch_file_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["patchGroups"][0]["patchFile"] = "patches/not-ready.patch"
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "planned but has patchFile"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_planned_group_with_postimage_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = fixture_manifest()
            manifest["patchGroups"][0]["postimageSHA256"] = {"a.txt": "a" * 64}
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "planned but has postimage"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_ported_group_with_unsafe_postimage_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            patch_text = "diff --git a/a.txt b/a.txt\n"
            manifest = fixture_manifest()
            patch = "patches/stable-surface.patch"
            manifest["patchGroups"][0]["status"] = "ported"
            manifest["patchGroups"][0]["patchFile"] = patch
            manifest["patchGroups"][0]["patchSHA256"] = hashlib.sha256(
                patch_text.encode("utf-8")
            ).hexdigest()
            manifest["patchGroups"][0]["postimageSHA256"] = {
                "/absolute/a.txt": "a" * 64
            }
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)
            patch_path = manifest_path.parent / patch
            patch_path.parent.mkdir(parents=True)
            patch_path.write_text(patch_text, encoding="utf-8")

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "postimageSHA256"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_rejects_ported_patch_containing_forbidden_scope_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            patch_text = "diff --git a/a.txt b/a.txt\n+# webdriver-hiding is forbidden\n"
            manifest = fixture_manifest()
            patch = "patches/stable-surface.patch"
            manifest["forbiddenScopes"] = ["webdriver-hiding"]
            manifest["patchGroups"][0]["status"] = "ported"
            manifest["patchGroups"][0]["patchFile"] = patch
            manifest["patchGroups"][0]["patchSHA256"] = hashlib.sha256(
                patch_text.encode("utf-8")
            ).hexdigest()
            manifest["patchGroups"][0]["postimageSHA256"] = {"a.txt": "a" * 64}
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)
            patch_path = manifest_path.parent / patch
            patch_path.parent.mkdir(parents=True)
            patch_path.write_text(patch_text, encoding="utf-8")

            with self.assertRaisesRegex(MODULE.PatchsetManifestError, "forbidden scope marker"):
                MODULE.verify_manifest(
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase_path,
                    release=False,
                )

    def test_ported_group_can_be_dry_run_applied_to_source_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_root = root / "chromium"
            source_root.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=source_root, check=True)
            (source_root / "a.txt").write_text("old\n", encoding="utf-8")
            subprocess.run(["git", "add", "a.txt"], cwd=source_root, check=True)
            patch_text = (
                "diff --git a/a.txt b/a.txt\n"
                "index 3367afd..3e75765 100644\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "+new\n"
            )
            manifest = fixture_manifest()
            manifest["status"] = "release-ready"
            patch = "patches/stable-surface.patch"
            manifest["patchGroups"][0]["status"] = "ported"
            manifest["patchGroups"][0]["patchFile"] = patch
            manifest["patchGroups"][0]["patchSHA256"] = hashlib.sha256(
                patch_text.encode("utf-8")
            ).hexdigest()
            manifest["patchGroups"][0]["postimageSHA256"] = {"a.txt": "a" * 64}
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)
            patch_path = manifest_path.parent / patch
            patch_path.parent.mkdir(parents=True)
            patch_path.write_text(patch_text, encoding="utf-8")

            summary = MODULE.verify_manifest(
                manifest_path=manifest_path,
                rebase_plan_path=rebase_path,
                release=True,
                source_root=source_root,
            )

        self.assertTrue(summary["releaseReady"])
        self.assertEqual(summary["portedCount"], 1)
        self.assertEqual(
            summary["groups"],
            [
                {
                    "id": "stable-surface",
                    "status": "ported",
                    "patchFile": "patches/stable-surface.patch",
                    "postimageCount": 1,
                    "sourceEvidenceCount": 1,
                    "requiredBehaviorCount": 1,
                }
            ],
        )

    def test_nested_source_root_cannot_silently_skip_patch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "checkout"
            source_root = repository / "build" / "src"
            source_root.mkdir(parents=True)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            (source_root / "a.txt").write_text("old\n", encoding="utf-8")
            patch_text = (
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "+new\n"
            )
            manifest = fixture_manifest()
            manifest["status"] = "release-ready"
            manifest["patchGroups"][0].update(
                {
                    "status": "ported",
                    "patchFile": "patches/stable.patch",
                    "patchSHA256": hashlib.sha256(
                        patch_text.encode("utf-8")
                    ).hexdigest(),
                    "postimageSHA256": {"a.txt": "a" * 64},
                }
            )
            manifest_path, rebase_path = write_fixture(root, manifest=manifest)
            patch_path = manifest_path.parent / "patches" / "stable.patch"
            patch_path.parent.mkdir(parents=True)
            patch_path.write_text(patch_text, encoding="utf-8")

            summary = MODULE.verify_manifest(
                manifest_path=manifest_path,
                rebase_plan_path=rebase_path,
                release=True,
                source_root=source_root,
            )

            self.assertTrue(summary["releaseReady"])


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def fixture_manifest() -> dict:
    return {
        "schemaVersion": 1,
        "targetChromiumVersion": "150.0.7871.186",
        "status": "planned-not-ported",
        "policy": "Fixture policy for planned Chromium 150 patchset verification.",
        "forbiddenScopes": ["automation-evasion"],
        "patchGroups": [
            {
                "id": "stable-surface",
                "title": "Stable surface",
                "status": "planned",
                "releaseRequired": True,
                "sourceEvidence": ["scripts/apply-runtime-overlay.py"],
                "patchFile": None,
                "patchSHA256": None,
                "requiredBehavior": ["stable A repeat"],
                "postimageSHA256": {},
            }
        ],
    }


def write_fixture(root: Path, *, manifest: dict | None = None) -> tuple[Path, Path]:
    manifest_path = root / "runtime" / "nevision-patches" / "series.json"
    rebase_path = root / "runtime" / "chromium-150-rebase-plan.json"
    manifest_path.parent.mkdir(parents=True)
    rebase_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "targetChromiumVersion": "150.0.7871.186",
            }
        ),
        encoding="utf-8",
    )
    manifest_path.write_text(json.dumps(copy.deepcopy(manifest or fixture_manifest())), encoding="utf-8")
    return manifest_path, rebase_path


if __name__ == "__main__":
    unittest.main()
