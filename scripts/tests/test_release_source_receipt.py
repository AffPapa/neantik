import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "release_source_receipt.py"
)
SPEC = importlib.util.spec_from_file_location(
    "release_source_receipt",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ReleaseSourceReceiptTests(unittest.TestCase):
    closure = (
        ("policy.json", "reviewed-policy"),
        ("scripts/release.py", "orchestrator"),
    )

    def git(self, root: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return completed.stdout.strip()

    def fixture(self, root: Path) -> None:
        (root / "scripts").mkdir()
        (root / "scripts" / "release.py").write_text(
            "print('release')\n",
            encoding="utf-8",
        )
        (root / "policy.json").write_text(
            '{"version":1}\n',
            encoding="utf-8",
        )
        (root / "README.md").write_text(
            "# Fixture\n",
            encoding="utf-8",
        )
        (root / ".gitignore").write_text(
            "dist/\n__pycache__/\n*.pyc\n",
            encoding="utf-8",
        )
        self.git(root, "init", "-q")
        self.git(root, "config", "user.name", "Test")
        self.git(root, "config", "user.email", "test@example.invalid")
        self.git(root, "add", ".")
        self.git(root, "commit", "-qm", "fixture")

    def test_clean_source_is_stable_and_path_remote_branch_independent(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            first = MODULE.capture_release_source(
                root,
                closure=self.closure,
            )
            self.git(root, "branch", "-m", "renamed")
            self.git(
                root,
                "remote",
                "add",
                "origin",
                "https://example.invalid/elsewhere.git",
            )
            os.utime(root / ".git" / "config", None)
            second = MODULE.capture_release_source(
                root,
                closure=self.closure,
            )

            self.assertEqual(first.payload, second.payload)
            self.assertNotIn(str(root), str(first.payload))
            self.assertNotIn("example.invalid", str(first.payload))
            self.assertEqual(
                first.payload["git"]["worktreeState"],  # type: ignore[index]
                "clean",
            )
            self.assertEqual(first.payload["schemaVersion"], 1)
            self.assertEqual(
                first.payload["repositoryClaim"],
                "AffPapa/neantik",
            )
            MODULE.assert_release_source_unchanged(second)

    def test_dirty_tracked_staged_and_untracked_source_fail_closed(
        self,
    ) -> None:
        mutations = ("tracked", "staged", "untracked")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    self.fixture(root)
                    if mutation == "tracked":
                        (root / "policy.json").write_text(
                            '{"version":2}\n',
                            encoding="utf-8",
                        )
                    elif mutation == "staged":
                        (root / "policy.json").write_text(
                            '{"version":2}\n',
                            encoding="utf-8",
                        )
                        self.git(root, "add", "policy.json")
                    else:
                        (root / "unexpected.txt").write_text(
                            "unexpected\n",
                            encoding="utf-8",
                        )
                    with self.assertRaisesRegex(
                        MODULE.ReleaseSourceReceiptError,
                        "not clean",
                    ):
                        MODULE.capture_release_source(
                            root,
                            closure=self.closure,
                        )

    def test_ignored_dist_does_not_dirty_release_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            (root / "dist").mkdir()
            (root / "dist" / "candidate.zip").write_bytes(b"candidate")
            MODULE.capture_release_source(root, closure=self.closure)

    def test_ignored_python_bytecode_cache_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            cache = root / "scripts" / "__pycache__"
            cache.mkdir()
            (cache / "release.cpython-311.pyc").write_bytes(b"bytecode")
            with self.assertRaisesRegex(
                MODULE.ReleaseSourceReceiptError,
                "bytecode",
            ):
                MODULE.capture_release_source(
                    root,
                    closure=self.closure,
                )

    def test_symlink_and_hardlink_closure_files_fail_closed(self) -> None:
        for mutation in ("symlink", "hardlink"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    self.fixture(root)
                    policy = root / "policy.json"
                    backup = root / "policy.backup"
                    policy.rename(backup)
                    if mutation == "symlink":
                        policy.symlink_to(backup.name)
                    else:
                        os.link(backup, policy)
                    with self.assertRaises(
                        MODULE.ReleaseSourceReceiptError
                    ):
                        MODULE.capture_release_source(
                            root,
                            closure=self.closure,
                        )

    def test_content_restore_is_detected_by_identity_seal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            snapshot = MODULE.capture_release_source(
                root,
                closure=self.closure,
            )
            policy = root / "policy.json"
            original = policy.read_bytes()
            policy.write_bytes(b'{"version":2}\n')
            policy.write_bytes(original)
            with self.assertRaisesRegex(
                MODULE.ReleaseSourceReceiptError,
                "changed",
            ):
                MODULE.assert_release_source_unchanged(snapshot)

    def test_nonclosure_content_restore_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            snapshot = MODULE.capture_release_source(
                root,
                closure=self.closure,
            )
            readme = root / "README.md"
            original = readme.read_bytes()
            readme.write_bytes(b"# Replaced\n")
            readme.write_bytes(original)
            with self.assertRaisesRegex(
                MODULE.ReleaseSourceReceiptError,
                "changed",
            ):
                MODULE.assert_release_source_unchanged(snapshot)

    def test_parent_directory_swap_and_restore_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            snapshot = MODULE.capture_release_source(
                root,
                closure=self.closure,
            )
            scripts = root / "scripts"
            original = root / "scripts-original"
            scripts.rename(original)
            scripts.mkdir()
            (scripts / "release.py").write_text(
                "print('replacement')\n",
                encoding="utf-8",
            )
            for child in scripts.iterdir():
                child.unlink()
            scripts.rmdir()
            original.rename(scripts)
            with self.assertRaisesRegex(
                MODULE.ReleaseSourceReceiptError,
                "directory changed",
            ):
                MODULE.assert_release_source_unchanged(snapshot)

    def test_runtime_evidence_is_honestly_split_from_reviewed_toolchain(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "candidate.json"
            critical = {
                key: {
                    "bundlePath": f"Contents/Evidence/{key}",
                    "sha256": f"{index:x}" * 64,
                }
                for index, key in enumerate(
                    (
                        "buildArguments",
                        "managerExecutable",
                        "managerInfoPlist",
                        "runtimeCandidateLock",
                        "runtimeExecutable",
                        "runtimeFramework",
                        "runtimeInfoPlist",
                        "runtimeVerification",
                        "sourceContract",
                        "sourceProvenance",
                    ),
                    start=1,
                )
            }
            manifest.write_text(
                json.dumps(
                    {
                        "schemaVersion": 3,
                        "criticalFiles": critical,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                encoding="utf-8",
            )
            snapshot = MODULE.ReleaseSourceSnapshot(
                project_root=root,
                payload={
                    "closure": [
                        {
                            "path": (
                                "runtime/"
                                "chromium-150-toolchain-lock.json"
                            ),
                            "role": "reviewed-toolchain-lock",
                            "sha256": "f" * 64,
                            "size": 10,
                        }
                    ]
                },
                files=(),
            )
            evidence = MODULE.runtime_build_evidence_from_manifest(
                snapshot,
                manifest,
            )

            self.assertEqual(
                evidence["reviewedToolchainLockSHA256"],
                "f" * 64,
            )
            self.assertEqual(evidence["schemaVersion"], 1)
            self.assertEqual(
                evidence["status"],
                "candidate-bound-reviewed-source",
            )
            self.assertEqual(
                evidence["runtimeCandidateLockSHA256"],
                "4" * 64,
            )
            self.assertNotIn("toolchainUsed", evidence)
            self.assertNotIn("reproducibleBuild", evidence)


if __name__ == "__main__":
    unittest.main()
