import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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

    def test_inventory_uses_the_captured_tree_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            expected_tree = self.git(root, "rev-parse", "HEAD^{tree}")
            original_run_git = MODULE._run_git
            queries: list[tuple[str, ...]] = []

            def recording_run_git(
                project_root: Path,
                arguments: list[str],
                **kwargs: object,
            ) -> bytes:
                queries.append(tuple(arguments))
                return original_run_git(
                    project_root,
                    arguments,
                    **kwargs,
                )

            with mock.patch.object(
                MODULE,
                "_run_git",
                side_effect=recording_run_git,
            ):
                MODULE.capture_release_source(
                    root,
                    closure=self.closure,
                )

            inventories = [
                query for query in queries if "ls-tree" in query
            ]
            self.assertEqual(len(inventories), 1)
            self.assertEqual(inventories[0][-1], expected_tree)
            self.assertNotIn("HEAD", inventories[0])

    def test_head_drift_during_capture_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            original_reader = MODULE._read_committed_blobs
            changed = False

            def change_head_after_read(*args: object, **kwargs: object):
                nonlocal changed
                result = original_reader(*args, **kwargs)
                if not changed:
                    changed = True
                    self.git(
                        root,
                        "commit",
                        "--allow-empty",
                        "-qm",
                        "concurrent ref movement",
                    )
                return result

            with mock.patch.object(
                MODULE,
                "_read_committed_blobs",
                side_effect=change_head_after_read,
            ):
                with self.assertRaisesRegex(
                    MODULE.ReleaseSourceReceiptError,
                    "changed while it was captured",
                ):
                    MODULE.capture_release_source(
                        root,
                        closure=self.closure,
                    )

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

    def test_nested_project_inside_parent_worktree_seals_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            self.git(parent, "init", "-q")
            self.git(parent, "config", "user.name", "Test")
            self.git(parent, "config", "user.email", "test@example.invalid")
            (parent / "README.md").write_text(
                "# Parent\n",
                encoding="utf-8",
            )
            self.git(parent, "add", "README.md")
            self.git(parent, "commit", "-qm", "parent")
            root = parent / "nevision"
            (root / "scripts").mkdir(parents=True)
            (root / "scripts" / "release.py").write_text(
                "print('release')\n",
                encoding="utf-8",
            )
            (root / "policy.json").write_text(
                '{"version":1}\n',
                encoding="utf-8",
            )

            snapshot = MODULE.capture_release_source(
                root,
                closure=self.closure,
            )

            self.assertEqual(
                snapshot.payload["git"]["worktreeState"],  # type: ignore[index]
                "nested-source-closure-sealed",
            )
            self.assertEqual(
                snapshot.payload["git"]["sourceRootRelativePath"],  # type: ignore[index]
                "nevision",
            )
            self.assertEqual(
                {seal.relative_path for seal in snapshot.files},
                {"policy.json", "scripts/release.py"},
            )
            MODULE.assert_release_source_unchanged(snapshot)

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

    def test_committed_blobs_use_one_batch_query_and_support_newline_path(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            unusual = root / "line\nbreak.txt"
            unusual.write_text("tracked\n", encoding="utf-8")
            duplicate = root / "duplicate-readme.txt"
            duplicate.write_bytes((root / "README.md").read_bytes())
            self.git(root, "add", unusual.name)
            self.git(root, "add", duplicate.name)
            self.git(root, "commit", "-qm", "unusual path")
            original_run = MODULE.subprocess.run
            commands: list[tuple[str, ...]] = []
            batch_requests: list[bytes] = []

            def recording_run(*args: object, **kwargs: object) -> object:
                command = args[0]
                if isinstance(command, list):
                    commands.append(tuple(str(item) for item in command))
                    if "cat-file" in command:
                        request = kwargs.get("input")
                        if isinstance(request, bytes):
                            batch_requests.append(request)
                return original_run(*args, **kwargs)

            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=recording_run,
            ):
                snapshot = MODULE.capture_release_source(
                    root,
                    closure=self.closure,
                )

            self.assertIn(
                "line\nbreak.txt",
                {seal.relative_path for seal in snapshot.files},
            )
            self.assertEqual(
                sum("cat-file" in command for command in commands),
                1,
            )
            self.assertFalse(
                any("show" in command for command in commands),
            )
            self.assertEqual(len(batch_requests), 1)
            self.assertLess(
                batch_requests[0].count(b"\0"),
                len(snapshot.files),
            )

    def test_malformed_batch_response_fails_closed(self) -> None:
        with mock.patch.object(
            MODULE.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=b"malformed\n",
                stderr=b"",
            ),
        ):
            with self.assertRaisesRegex(
                MODULE.ReleaseSourceReceiptError,
                "blob response",
            ):
                MODULE._read_committed_blobs(  # noqa: SLF001
                    Path("."),
                    (("a" * 40, 0),),
                    identifier_length=40,
                )

    def test_aggregate_blob_limit_fails_before_git_query(self) -> None:
        objects = tuple(
            (f"{index:040x}", MODULE._MAXIMUM_SOURCE_FILE_BYTES)
            for index in range(9)
        )
        with mock.patch.object(
            MODULE.subprocess,
            "run",
            side_effect=AssertionError("Git must not run"),
        ):
            with self.assertRaisesRegex(
                MODULE.ReleaseSourceReceiptError,
                "batch memory limit",
            ):
                MODULE._read_committed_blobs(  # noqa: SLF001
                    Path("."),
                    objects,
                    identifier_length=40,
                )

    def test_blob_cardinality_limit_fails_before_git_query(self) -> None:
        objects = tuple(
            ("a" * 40, 0)
            for _index in range(MODULE._MAXIMUM_TRACKED_FILES + 1)
        )
        with mock.patch.object(
            MODULE.subprocess,
            "run",
            side_effect=AssertionError("Git must not run"),
        ):
            with self.assertRaisesRegex(
                MODULE.ReleaseSourceReceiptError,
                "too many tracked files",
            ):
                MODULE._read_committed_blobs(  # noqa: SLF001
                    Path("."),
                    objects,
                    identifier_length=40,
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
                                "chromium-151-toolchain-lock.json"
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
