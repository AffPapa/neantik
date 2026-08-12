import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "apply-neantik-patchset.py"
SPEC = importlib.util.spec_from_file_location("apply_neantik_patchset", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ApplyNeAntikPatchsetTests(unittest.TestCase):
    def fixture(
        self,
        root: Path,
        *,
        nested_worktree: bool = False,
    ) -> tuple[Path, Path, Path]:
        source = root / "checkout" / "build" / "src" if nested_worktree else root / "src"
        source.mkdir(parents=True)
        git_root = source.parents[1] if nested_worktree else source
        subprocess.run(["git", "init", "-q"], cwd=git_root, check=True)
        (source / "chrome").mkdir()
        (source / "chrome" / "VERSION").write_text(
            "MAJOR=150\nMINOR=0\nBUILD=7871\nPATCH=186\n",
            encoding="utf-8",
        )
        (source / "a.txt").write_text("old\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=source, check=True)

        patch_text = (
            "diff --git a/a.txt b/a.txt\n"
            "index 3367afd..3e75765 100644\n"
            "--- a/a.txt\n"
            "+++ b/a.txt\n"
            "@@ -1 +1 @@\n"
            "-old\n"
            "+new\n"
        )
        manifest_root = root / "runtime" / "nevision-patches"
        patch_path = manifest_root / "patches" / "stable.patch"
        patch_path.parent.mkdir(parents=True)
        patch_path.write_text(patch_text, encoding="utf-8")
        generated_root = root / "generated"
        generated_root.mkdir()
        (generated_root / "catalog.json").write_text("{}\n", encoding="utf-8")
        (generated_root / "generator.py").write_text(
            "# fixture\n",
            encoding="utf-8",
        )
        manifest = {
            "schemaVersion": 1,
            "targetChromiumVersion": "150.0.7871.186",
            "status": "release-ready",
            "policy": "Test policy.",
            "forbiddenScopes": ["automation-evasion"],
            "generatedInputs": [
                {
                    "id": "fixture-generated-input",
                    "catalogPath": "generated/catalog.json",
                    "catalogSHA256": hashlib.sha256(b"{}\n").hexdigest(),
                    "generatorPath": "generated/generator.py",
                    "generatorSHA256": hashlib.sha256(
                        b"# fixture\n"
                    ).hexdigest(),
                    "postimageSHA256": {
                        "a.txt": hashlib.sha256(b"generated\n").hexdigest()
                    },
                }
            ],
            "patchGroups": [
                {
                    "id": "stable",
                    "title": "Stable",
                    "status": "ported",
                    "releaseRequired": True,
                    "sourceEvidence": ["owner.txt"],
                    "patchFile": "patches/stable.patch",
                    "patchSHA256": hashlib.sha256(
                        patch_text.encode("utf-8")
                    ).hexdigest(),
                    "requiredBehavior": ["stable"],
                    "postimageSHA256": {
                        "a.txt": hashlib.sha256(b"new\n").hexdigest()
                    },
                }
            ],
        }
        manifest_path = manifest_root / "series.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        rebase_path = root / "runtime" / "chromium-150-rebase-plan.json"
        rebase_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "targetChromiumVersion": "150.0.7871.186",
                }
            ),
            encoding="utf-8",
        )
        (MODULE.PROJECT_ROOT / "owner.txt").write_text("owner\n", encoding="utf-8")
        self.addCleanup((MODULE.PROJECT_ROOT / "owner.txt").unlink, missing_ok=True)
        return source, manifest_path, rebase_path

    def test_check_then_apply_then_idempotent_verify(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, manifest, rebase = self.fixture(Path(temporary))

            ready = MODULE.apply_patchset(
                source_root=source,
                manifest_path=manifest,
                rebase_plan_path=rebase,
                check_only=True,
            )
            applied = MODULE.apply_patchset(
                source_root=source,
                manifest_path=manifest,
                rebase_plan_path=rebase,
            )
            repeated = MODULE.apply_patchset(
                source_root=source,
                manifest_path=manifest,
                rebase_plan_path=rebase,
            )

            self.assertEqual(ready["status"], "ready-to-apply")
            self.assertEqual(applied["status"], "applied")
            self.assertEqual(repeated["status"], "already-applied")
            self.assertEqual((source / "a.txt").read_text(), "new\n")

    def test_generated_postimage_is_an_idempotent_final_patch_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, manifest, rebase = self.fixture(Path(temporary))
            MODULE.apply_patchset(
                source_root=source,
                manifest_path=manifest,
                rebase_plan_path=rebase,
            )
            (source / "a.txt").write_text("generated\n", encoding="utf-8")

            repeated = MODULE.apply_patchset(
                source_root=source,
                manifest_path=manifest,
                rebase_plan_path=rebase,
            )

            self.assertEqual(repeated["status"], "already-applied")

    def test_explicit_incremental_preimage_recovers_one_appended_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, manifest_path, rebase = self.fixture(Path(temporary))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            first_patch = (
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "+middle\n"
            )
            second_patch = (
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-middle\n"
                "+new\n"
            )
            patch_root = manifest_path.parent / "patches"
            (patch_root / "first.patch").write_text(
                first_patch,
                encoding="utf-8",
            )
            (patch_root / "second.patch").write_text(
                second_patch,
                encoding="utf-8",
            )
            common = {
                "title": "Incremental fixture",
                "status": "ported",
                "releaseRequired": True,
                "sourceEvidence": ["owner.txt"],
                "requiredBehavior": ["stable"],
            }
            manifest["patchGroups"] = [
                {
                    **common,
                    "id": "first",
                    "patchFile": "patches/first.patch",
                    "patchSHA256": hashlib.sha256(
                        first_patch.encode("utf-8")
                    ).hexdigest(),
                    "postimageSHA256": {
                        "a.txt": hashlib.sha256(b"middle\n").hexdigest()
                    },
                },
                {
                    **common,
                    "id": "second",
                    "patchFile": "patches/second.patch",
                    "patchSHA256": hashlib.sha256(
                        second_patch.encode("utf-8")
                    ).hexdigest(),
                    "incrementalPreimageSHA256": {
                        "a.txt": hashlib.sha256(b"middle\n").hexdigest()
                    },
                    "postimageSHA256": {
                        "a.txt": hashlib.sha256(b"new\n").hexdigest()
                    },
                },
            ]
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            (source / "a.txt").write_text("middle\n", encoding="utf-8")

            recovered = MODULE.apply_patchset(
                source_root=source,
                manifest_path=manifest_path,
                rebase_plan_path=rebase,
                recover_incremental=True,
            )

            self.assertEqual(recovered["status"], "incrementally-recovered")
            self.assertEqual(recovered["group"], "second")
            self.assertEqual((source / "a.txt").read_text(), "new\n")

    def test_later_patch_postimage_supersedes_shared_intermediate_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "shared.txt").write_text("final\n", encoding="utf-8")
            groups = [
                {
                    "id": "first",
                    "postimageSHA256": {
                        "shared.txt": hashlib.sha256(b"middle\n").hexdigest()
                    },
                },
                {
                    "id": "second",
                    "postimageSHA256": {
                        "shared.txt": hashlib.sha256(b"final\n").hexdigest()
                    },
                },
            ]

            matched, total, mismatches = MODULE.postimage_state(
                source,
                groups,
                {},
            )

            self.assertEqual(matched, 2)
            self.assertEqual(total, 2)
            self.assertEqual(mismatches, [])

    def test_dependent_patch_series_is_checked_and_committed_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src"
            source.mkdir()
            (source / "a.txt").write_text("old\n", encoding="utf-8")
            first = root / "first.patch"
            first.write_text(
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "+middle\n",
                encoding="utf-8",
            )
            second = root / "second.patch"
            second.write_text(
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-middle\n"
                "+final\n",
                encoding="utf-8",
            )

            MODULE.run_patch_series_transaction(
                source,
                [first, second],
                check_only=True,
            )
            self.assertEqual((source / "a.txt").read_text(), "old\n")

            MODULE.run_patch_series_transaction(
                source,
                [first, second],
                check_only=False,
            )
            self.assertEqual((source / "a.txt").read_text(), "final\n")

    def test_failed_dependent_patch_series_does_not_modify_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src"
            source.mkdir()
            (source / "a.txt").write_text("old\n", encoding="utf-8")
            first = root / "first.patch"
            first.write_text(
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "+middle\n",
                encoding="utf-8",
            )
            invalid = root / "invalid.patch"
            invalid.write_text(
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-unexpected\n"
                "+final\n",
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.PatchApplicationError):
                MODULE.run_patch_series_transaction(
                    source,
                    [first, invalid],
                    check_only=False,
                )

            self.assertEqual((source / "a.txt").read_text(), "old\n")

    def test_concurrent_transaction_requires_exclusive_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src"
            source.mkdir()
            (source / "a.txt").write_text("old\n", encoding="utf-8")
            patch = root / "change.patch"
            patch.write_text(
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "+new\n",
                encoding="utf-8",
            )

            with MODULE.exclusive_transaction_lock(source):
                with self.assertRaisesRegex(
                    MODULE.PatchApplicationError,
                    "already locked",
                ):
                    MODULE.run_patch_series_transaction(
                        source,
                        [patch],
                        check_only=False,
                    )

            self.assertEqual((source / "a.txt").read_text(), "old\n")

    def test_failed_new_file_postimage_removes_created_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src"
            source.mkdir()
            patch = root / "new-file.patch"
            patch.write_text(
                "diff --git a/new.txt b/new.txt\n"
                "new file mode 100644\n"
                "--- /dev/null\n"
                "+++ b/new.txt\n"
                "@@ -0,0 +1 @@\n"
                "+created\n",
                encoding="utf-8",
            )

            def reject_commit() -> None:
                raise MODULE.PostimageValidationError("fixture mismatch")

            with self.assertRaisesRegex(
                MODULE.PostimageValidationError,
                "fixture mismatch",
            ):
                MODULE.run_patch_series_transaction(
                    source,
                    [patch],
                    check_only=False,
                    validate_commit=reject_commit,
                )

            self.assertFalse((source / "new.txt").exists())

    def test_parent_symlink_is_rejected_without_touching_outside(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src"
            outside = root / "outside"
            source.mkdir()
            outside.mkdir()
            victim = outside / "victim.txt"
            victim.write_text("old\n", encoding="utf-8")
            (source / "linked").symlink_to(outside, target_is_directory=True)
            patch = root / "escape.patch"
            patch.write_text(
                "diff --git a/linked/victim.txt b/linked/victim.txt\n"
                "--- a/linked/victim.txt\n"
                "+++ b/linked/victim.txt\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "+new\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PatchApplicationError,
                "symlinked directory|escapes",
            ):
                MODULE.run_patch_series_transaction(
                    source,
                    [patch],
                    check_only=False,
                )

            self.assertEqual(victim.read_text(encoding="utf-8"), "old\n")

    def test_failed_incremental_recovery_restores_content_and_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src"
            source.mkdir()
            target = source / "a.txt"
            target.write_text("middle\n", encoding="utf-8")
            target.chmod(0o640)
            patch_root = root / "runtime" / "nevision-patches"
            patch_root.mkdir(parents=True)
            patch = patch_root / "second.patch"
            patch.write_text(
                "diff --git a/a.txt b/a.txt\n"
                "--- a/a.txt\n"
                "+++ b/a.txt\n"
                "@@ -1 +1 @@\n"
                "-middle\n"
                "+new\n",
                encoding="utf-8",
            )
            groups = [
                {
                    "id": "second",
                    "patchFile": "second.patch",
                    "incrementalPreimageSHA256": {
                        "a.txt": hashlib.sha256(b"middle\n").hexdigest()
                    },
                    "postimageSHA256": {
                        "a.txt": hashlib.sha256(b"wrong\n").hexdigest()
                    },
                }
            ]

            with self.assertRaisesRegex(
                MODULE.PatchApplicationError,
                "Incremental recovery did not produce",
            ):
                MODULE.recover_one_incremental_group(
                    source_root=source,
                    manifest_path=patch_root / "series.json",
                    groups=groups,
                    generated_postimages={},
                )

            self.assertEqual(target.read_text(encoding="utf-8"), "middle\n")
            self.assertEqual(os.stat(target).st_mode & 0o777, 0o640)

    def test_postimage_failure_atomically_restores_patch_preimage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, manifest_path, rebase = self.fixture(Path(temporary))
            (source / "a.txt").chmod(0o640)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["patchGroups"][0]["postimageSHA256"]["a.txt"] = (
                hashlib.sha256(b"not-the-patch-result\n").hexdigest()
            )
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.PatchApplicationError,
                "Postimage verification failed",
            ):
                MODULE.apply_patchset(
                    source_root=source,
                    manifest_path=manifest_path,
                    rebase_plan_path=rebase,
                )

            self.assertEqual((source / "a.txt").read_text(), "old\n")
            self.assertEqual(os.stat(source / "a.txt").st_mode & 0o777, 0o640)

    def test_rejects_wrong_chromium_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, manifest, rebase = self.fixture(Path(temporary))
            (source / "chrome" / "VERSION").write_text(
                "MAJOR=149\nMINOR=0\nBUILD=1\nPATCH=2\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PatchApplicationError,
                "Chromium version mismatch",
            ):
                MODULE.apply_patchset(
                    source_root=source,
                    manifest_path=manifest,
                    rebase_plan_path=rebase,
                )

    def test_nested_source_root_is_anchored_in_parent_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, manifest, rebase = self.fixture(
                Path(temporary),
                nested_worktree=True,
            )

            result = MODULE.apply_patchset(
                source_root=source,
                manifest_path=manifest,
                rebase_plan_path=rebase,
            )

            self.assertEqual(result["status"], "applied")
            self.assertEqual((source / "a.txt").read_text(), "new\n")


if __name__ == "__main__":
    unittest.main()
