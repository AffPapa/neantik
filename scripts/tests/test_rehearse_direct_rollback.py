import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "rehearse-direct-rollback.py"
SPEC = importlib.util.spec_from_file_location("rollback_rehearsal", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class RollbackRehearsalTests(unittest.TestCase):
    def fixture(self, root):
        evidence_path = root / "release.json"
        artifacts = root / "dist"
        artifacts.mkdir()
        records = []
        for name, content in (("NeAntik-test.zip", b"zip bytes"), ("NeAntik-test.dmg", b"dmg bytes")):
            artifact = artifacts / name
            artifact.write_bytes(content)
            digest = MODULE.sha256(artifact)
            (artifacts / f"{name}.sha256").write_text(f"{digest}  {name}\n")
            records.append({"name": name, "sizeBytes": len(content), "sha256": digest})
        evidence_path.write_text(json.dumps({
            "tag": "v1.2.3", "archive": records[0], "dmg": records[1]
        }))
        return evidence_path, artifacts

    def test_stages_and_verifies_exact_bytes_without_changing_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence, artifacts = self.fixture(Path(temporary))
            before = {path.name: path.read_bytes() for path in artifacts.iterdir()}
            result = MODULE.rehearse(evidence, artifacts)
            after = {path.name: path.read_bytes() for path in artifacts.iterdir()}
        self.assertEqual(result["state"], "passed")
        self.assertEqual(len(result["artifacts"]), 2)
        self.assertEqual(before, after)
        self.assertIn("Does not install", result["limitations"])

    def test_tampered_artifact_blocks(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence, artifacts = self.fixture(Path(temporary))
            (artifacts / "NeAntik-test.zip").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "does not match"):
                MODULE.rehearse(evidence, artifacts)

    def test_symlinked_artifact_blocks(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence, artifacts = self.fixture(Path(temporary))
            target = artifacts / "NeAntik-test.zip"
            content = target.read_bytes()
            target.unlink()
            external = Path(temporary) / "external.zip"
            external.write_bytes(content)
            target.symlink_to(external)
            with self.assertRaisesRegex(ValueError, "missing"):
                MODULE.rehearse(evidence, artifacts)

    def test_unsafe_release_name_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence, artifacts = self.fixture(Path(temporary))
            data = json.loads(evidence.read_text())
            data["archive"]["name"] = "../private.zip"
            evidence.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "evidence is invalid"):
                MODULE.rehearse(evidence, artifacts)


if __name__ == "__main__":
    unittest.main()
