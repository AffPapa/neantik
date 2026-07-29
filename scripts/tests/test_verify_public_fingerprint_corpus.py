import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-public-fingerprint-corpus.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_public_fingerprint_corpus",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VerifyPublicFingerprintCorpusTests(unittest.TestCase):
    def test_accepts_repository_corpus(self) -> None:
        result = MODULE.verify_public_corpus()

        self.assertIn("9 synthetic cases", result)

    def test_rejects_real_profile_name(self) -> None:
        with self.corpus_copy() as corpus:
            base_path = corpus / "base-production-qualified.json"
            report = json.loads(base_path.read_text(encoding="utf-8"))
            report["firstInitial"]["profileName"] = "Alice Personal"
            base_path.write_text(
                json.dumps(report),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PublicFingerprintCorpusError,
                "non-synthetic profile name",
            ):
                MODULE.verify_public_corpus(corpus)

    def test_rejects_local_user_path(self) -> None:
        with self.corpus_copy() as corpus:
            base_path = corpus / "base-production-qualified.json"
            report = json.loads(base_path.read_text(encoding="utf-8"))
            report["runtimeName"] = "/Users/alice/Private Browser"
            base_path.write_text(
                json.dumps(report),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PublicFingerprintCorpusError,
                "local path or secret marker",
            ):
                MODULE.verify_public_corpus(corpus)

    def test_rejects_sensitive_field_even_with_synthetic_value(self) -> None:
        with self.corpus_copy() as corpus:
            base_path = corpus / "base-production-qualified.json"
            report = json.loads(base_path.read_text(encoding="utf-8"))
            report["firstInitial"]["values"]["proxyPassword"] = "synthetic"
            base_path.write_text(
                json.dumps(report),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PublicFingerprintCorpusError,
                "Forbidden sensitive field",
            ):
                MODULE.verify_public_corpus(corpus)

    def test_rejects_expected_outcome_drift(self) -> None:
        with self.corpus_copy() as corpus:
            manifest_path = corpus / "manifest.json"
            manifest = json.loads(
                manifest_path.read_text(encoding="utf-8")
            )
            manifest["cases"][0]["productionQualified"] = False
            manifest_path.write_text(
                json.dumps(manifest),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PublicFingerprintCorpusError,
                "expected",
            ):
                MODULE.verify_public_corpus(corpus)

    def test_rejects_non_allowlisted_mutation(self) -> None:
        with self.corpus_copy() as corpus:
            manifest_path = corpus / "manifest.json"
            manifest = json.loads(
                manifest_path.read_text(encoding="utf-8")
            )
            manifest["cases"][1]["mutations"][0]["path"] = (
                "firstInitial.profileName"
            )
            manifest_path.write_text(
                json.dumps(manifest),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                MODULE.PublicFingerprintCorpusError,
                "not allowlisted",
            ):
                MODULE.verify_public_corpus(corpus)

    def corpus_copy(self):
        temporary = tempfile.TemporaryDirectory()
        destination = Path(temporary.name) / "corpus"
        shutil.copytree(MODULE.DEFAULT_CORPUS, destination)

        class CorpusContext:
            def __enter__(self):
                return destination

            def __exit__(self, *args):
                temporary.cleanup()

        return CorpusContext()


if __name__ == "__main__":
    unittest.main()
