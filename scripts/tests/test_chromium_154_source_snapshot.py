from __future__ import annotations

import importlib.util
import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "chromium_154_source_snapshot.py"
SPEC = importlib.util.spec_from_file_location("m154_source_snapshot", SCRIPT)
assert SPEC and SPEC.loader
SNAPSHOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SNAPSHOT)


class Chromium154SourceSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "src"
        self.root.mkdir()
        (self.root / "chrome").mkdir()
        (self.root / "out" / "Default").mkdir(parents=True)
        (self.root / "chrome" / "VERSION").write_text(
            "MAJOR=154\nMINOR=0\nBUILD=8037\nPATCH=93\n",
            encoding="utf-8",
        )
        (self.root / "input.txt").write_text("original\n", encoding="utf-8")
        (self.root / "out" / "Default" / "args.gn").write_text(
            'target_cpu = "arm64"\n', encoding="utf-8"
        )
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "chrome", "input.txt"], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"],
            check=True,
        )
        SNAPSHOT.COMMIT = subprocess.check_output(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True
        ).strip()
        SNAPSHOT.TREE = subprocess.check_output(
            ["git", "-C", str(self.root), "rev-parse", "HEAD^{tree}"], text=True
        ).strip()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_snapshot_changes_when_modified_or_untracked_inputs_change(self) -> None:
        original = SNAPSHOT.build_snapshot(self.root, self.root / "out/Default/args.gn")
        (self.root / "input.txt").write_text("modified\n", encoding="utf-8")
        modified = SNAPSHOT.build_snapshot(self.root, self.root / "out/Default/args.gn")
        self.assertNotEqual(original, modified)

        (self.root / "new-input.txt").write_text("new\n", encoding="utf-8")
        added = SNAPSHOT.build_snapshot(self.root, self.root / "out/Default/args.gn")
        self.assertNotEqual(modified, added)

    def test_snapshot_records_deleted_inputs_and_excludes_output_tree(self) -> None:
        (self.root / "input.txt").unlink()
        (self.root / "out" / "Default" / "generated.o").write_bytes(b"build output")
        snapshot = SNAPSHOT.build_snapshot(self.root, self.root / "out/Default/args.gn")
        self.assertEqual(snapshot["deletedPaths"], ["input.txt"])
        self.assertNotIn("out/Default/generated.o", {entry["path"] for entry in snapshot["entries"]})

    def test_compact_snapshot_binds_every_inventory_field(self) -> None:
        full = SNAPSHOT.build_snapshot(self.root, self.root / "out/Default/args.gn")
        compact = SNAPSHOT.compact_snapshot(full)
        self.assertNotIn("entries", compact)
        self.assertNotIn("deletedPaths", compact)
        self.assertEqual(compact["schemaVersion"], 2)
        expected = hashlib.sha256(json.dumps(
            full["entries"], sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode()).hexdigest()
        self.assertEqual(compact["entriesSHA256"], expected)
        for field, value in (("mode", 0o755), ("path", "renamed"),
                             ("sha256", "0" * 64), ("sizeBytes", 999)):
            altered = copy.deepcopy(full)
            altered["entries"][0][field] = value
            self.assertNotEqual(compact, SNAPSHOT.compact_snapshot(altered), field)

    def test_compact_snapshot_changes_for_deleted_paths_and_args(self) -> None:
        full = SNAPSHOT.build_snapshot(self.root, self.root / "out/Default/args.gn")
        before = SNAPSHOT.compact_snapshot(full)
        full["deletedPaths"] = ["removed.txt"]
        full["deletedPathCount"] = 1
        self.assertNotEqual(before, SNAPSHOT.compact_snapshot(full))
        before = SNAPSHOT.compact_snapshot(full)
        full["argsGN"]["sha256"] = "0" * 64
        self.assertNotEqual(before, SNAPSHOT.compact_snapshot(full))

    def test_compact_snapshot_rejects_inconsistent_inventory_counts(self) -> None:
        full = SNAPSHOT.build_snapshot(self.root, self.root / "out/Default/args.gn")
        full["sourceFileCount"] += 1
        with self.assertRaises(SNAPSHOT.SnapshotError):
            SNAPSHOT.compact_snapshot(full)

    def test_compact_cli_verifies_live_inventory_and_rejects_mutation(self) -> None:
        output = Path(self.temporary.name) / "compact.json"
        argv = [str(SCRIPT), str(self.root), str(self.root / "out/Default/args.gn"),
                "--output", str(output)]
        with mock.patch("sys.argv", argv + ["--compact"]):
            self.assertEqual(SNAPSHOT.main(), 0)
        self.assertEqual(json.loads(output.read_text())["schemaVersion"], 2)
        with mock.patch("sys.argv", argv + ["--verify"]):
            self.assertEqual(SNAPSHOT.main(), 0)
        (self.root / "input.txt").write_text("tampered\n")
        with mock.patch("sys.argv", argv + ["--verify"]):
            self.assertEqual(SNAPSHOT.main(), 1)


if __name__ == "__main__":
    unittest.main()
