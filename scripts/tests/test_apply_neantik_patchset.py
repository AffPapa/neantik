import hashlib
import importlib.util
import json
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
