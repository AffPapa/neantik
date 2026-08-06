import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "direct-candidate-source-binding.py"
)
SPEC = importlib.util.spec_from_file_location(
    "direct_candidate_source_binding",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


class DirectCandidateSourceBindingTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, Path]:
        git(root, "init", "-q")
        git(root, "config", "user.email", "tests@example.invalid")
        git(root, "config", "user.name", "NeAntik Tests")
        source = root / "source.txt"
        source.write_text("first\n", encoding="utf-8")
        (root / ".gitignore").write_text(
            "candidate.json\nbinding.json\n",
            encoding="utf-8",
        )
        git(root, "add", "source.txt", ".gitignore")
        git(root, "commit", "-qm", "initial")
        manifest = root / "candidate.json"
        manifest.write_text('{"schemaVersion":3}', encoding="utf-8")
        binding = root / "binding.json"
        return manifest, binding

    def test_round_trip_binds_commit_tree_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, binding = self.fixture(root)

            created = MODULE.create_binding(root, manifest, binding)
            verified = MODULE.verify_binding(root, manifest, binding)
            payload = json.loads(binding.read_text(encoding="utf-8"))

            self.assertEqual(created, verified)
            self.assertEqual(payload["commit"], git(root, "rev-parse", "HEAD"))
            self.assertEqual(
                payload["tree"],
                git(root, "rev-parse", "HEAD^{tree}"),
            )
            self.assertEqual(binding.stat().st_mode & 0o777, 0o600)

    def test_rejects_new_commit_even_when_candidate_is_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, binding = self.fixture(root)
            MODULE.create_binding(root, manifest, binding)
            (root / "source.txt").write_text("second\n", encoding="utf-8")
            git(root, "add", "source.txt")
            git(root, "commit", "-qm", "next")

            with self.assertRaisesRegex(
                MODULE.CandidateSourceBindingError,
                "exact current source commit",
            ):
                MODULE.verify_binding(root, manifest, binding)

    def test_rejects_manifest_drift_and_dirty_tracked_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, binding = self.fixture(root)
            MODULE.create_binding(root, manifest, binding)
            manifest.write_text('{"schemaVersion":4}', encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.CandidateSourceBindingError,
                "exact current source commit",
            ):
                MODULE.verify_binding(root, manifest, binding)

            manifest.write_text('{"schemaVersion":3}', encoding="utf-8")
            (root / "source.txt").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.CandidateSourceBindingError,
                "not clean",
            ):
                MODULE.verify_binding(root, manifest, binding)

    def test_rejects_untracked_swift_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, binding = self.fixture(root)
            untracked = root / "Sources/NeAntik/Injected.swift"
            untracked.parent.mkdir(parents=True)
            untracked.write_text("let injected = true\n", encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.CandidateSourceBindingError,
                "not clean",
            ):
                MODULE.create_binding(root, manifest, binding)


if __name__ == "__main__":
    unittest.main()
