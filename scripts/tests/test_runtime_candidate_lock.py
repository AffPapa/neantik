import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = PROJECT_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import runtime_candidate_lock as CANDIDATE  # noqa: E402
import runtime_source_provenance as SOURCE  # noqa: E402

PROMOTION_PATH = SCRIPTS / "promote-runtime-candidate-lock.py"
PROMOTION_SPEC = importlib.util.spec_from_file_location(
    "promote_runtime_candidate_lock",
    PROMOTION_PATH,
)
assert PROMOTION_SPEC and PROMOTION_SPEC.loader
PROMOTION = importlib.util.module_from_spec(PROMOTION_SPEC)
PROMOTION_SPEC.loader.exec_module(PROMOTION)


class RuntimeCandidateLockTests(unittest.TestCase):
    def write_provenance(self, root: Path) -> Path:
        document = SOURCE.expected_static_document(
            project_root=PROJECT_ROOT,
        )
        document["sourceChecks"] = {
            "chromiumVersion": "verified",
            "officialArchiveSHA256": "verified",
            "macGitObjects": "verified",
            "commonGitObjects": "verified",
            "ownedPatchset": "already-applied",
            "ownedAppleDeviceTuples": "verified",
        }
        path = root / "source-provenance.json"
        SOURCE.atomic_write_json(path, document)
        return path

    def write_candidate(self, root: Path) -> tuple[Path, Path, dict]:
        provenance = self.write_provenance(root)
        candidate = CANDIDATE.expected_candidate_lock(
            provenance,
            project_root=PROJECT_ROOT,
        )
        path = root / "runtime-candidate-lock.json"
        SOURCE.atomic_write_json(path, candidate)
        return path, provenance, candidate

    def test_candidate_is_deterministic_and_source_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            provenance = self.write_provenance(root)
            first = CANDIDATE.expected_candidate_lock(
                provenance,
                project_root=PROJECT_ROOT,
            )
            second = CANDIDATE.expected_candidate_lock(
                provenance,
                project_root=PROJECT_ROOT,
            )

        self.assertEqual(first, second)
        self.assertEqual(first["schemaVersion"], 4)
        self.assertEqual(first["status"], "source-qualified")
        self.assertEqual(
            first["binaryBinding"]["status"],
            "not-attested-by-this-document",
        )
        text = json.dumps(first, sort_keys=True)
        self.assertNotIn("runtimeReport", text)
        self.assertNotIn("executable", text)
        self.assertNotIn("framework", text)
        self.assertNotIn("createdAt", text)
        self.assertNotIn("/Users/", text)
        self.assertNotIn("/private/tmp/", text)
        self.assertNotIn("144.0.7559", text)
        self.assertNotIn("6bbb0dbdeae887af207c75c9e5173cceddbd381b", text)

    def test_candidate_hash_has_no_provenance_cycle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_path, provenance_path, candidate = self.write_candidate(
                root
            )
            provenance = json.loads(
                provenance_path.read_text(encoding="utf-8")
            )
            provenance_sha = SOURCE.sha256_file(provenance_path)
            candidate_sha = SOURCE.sha256_file(candidate_path)

            self.assertEqual(
                candidate["sourceProvenanceSHA256"],
                provenance_sha,
            )
            self.assertNotIn("candidateLockSHA256", provenance)
            self.assertNotIn(
                candidate_sha,
                json.dumps(provenance, sort_keys=True),
            )

    def test_rejects_mutation_and_stale_144_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_path, provenance, candidate = self.write_candidate(root)
            changed = copy.deepcopy(candidate)
            changed["sourceProvenanceSHA256"] = "0" * 64
            SOURCE.atomic_write_json(candidate_path, changed)
            with self.assertRaisesRegex(
                SOURCE.SourceProvenanceError,
                "stale or mutated",
            ):
                CANDIDATE.verify_candidate_lock(
                    candidate_path,
                    provenance,
                    project_root=PROJECT_ROOT,
                )

            changed = copy.deepcopy(candidate)
            changed["macPackaging"]["commit"] = (
                "6bbb0dbdeae887af207c75c9e5173cceddbd381b"
            )
            SOURCE.atomic_write_json(candidate_path, changed)
            with self.assertRaisesRegex(
                SOURCE.SourceProvenanceError,
                "stale Chromium 144",
            ):
                CANDIDATE.verify_candidate_lock(
                    candidate_path,
                    provenance,
                    project_root=PROJECT_ROOT,
                )

    def test_exporter_refuses_published_lock(self) -> None:
        with self.assertRaisesRegex(
            SOURCE.SourceProvenanceError,
            "never overwrite",
        ):
            CANDIDATE.refuse_published_lock_output(
                PROJECT_ROOT
                / "runtime"
                / "fingerprint-chromium.lock.json",
                project_root=PROJECT_ROOT,
            )

    def test_wrong_lock_report_binding_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_path, provenance, candidate = self.write_candidate(root)
            args_gn = root / "src" / "out" / "Default" / "args.gn"
            args_gn.parent.mkdir(parents=True)
            args_gn.write_text(
                'target_cpu = "arm64"\nangle_enable_metal = true\n',
                encoding="utf-8",
            )
            report = {
                "schemaVersion": 3,
                "gpuMode": "metal",
                "candidateLockSHA256": SOURCE.sha256_file(candidate_path),
                "sourceLockSHA256": SOURCE.sha256_file(candidate_path),
                "sourceContractSHA256": candidate["sourceContractSHA256"],
                "sourceProvenanceSHA256": SOURCE.sha256_file(provenance),
                "chromiumVersion":
                    candidate["fingerprintChromium"]["chromiumVersion"],
                "buildArguments": {
                    "sha256": SOURCE.sha256_file(args_gn),
                },
                "executable": {"sha256": "a" * 64},
                "framework": {"sha256": "b" * 64},
            }
            report_path = root / "runtime-report.json"
            SOURCE.atomic_write_json(report_path, report)

            PROMOTION.validate_report_binding(
                candidate_path,
                provenance,
                args_gn,
                report_path,
                project_root=PROJECT_ROOT,
            )
            report["candidateLockSHA256"] = "0" * 64
            SOURCE.atomic_write_json(report_path, report)
            with self.assertRaisesRegex(
                SOURCE.SourceProvenanceError,
                "candidateLockSHA256 mismatch",
            ):
                PROMOTION.validate_report_binding(
                    candidate_path,
                    provenance,
                    args_gn,
                    report_path,
                    project_root=PROJECT_ROOT,
                )

    def test_non_metal_report_cannot_promote(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_path, provenance, _ = self.write_candidate(root)
            args_gn = root / "src" / "out" / "Default" / "args.gn"
            args_gn.parent.mkdir(parents=True)
            args_gn.write_text(
                'target_cpu = "arm64"\nangle_enable_metal = false\n',
                encoding="utf-8",
            )
            report = root / "runtime-report.json"
            SOURCE.atomic_write_json(report, {})
            with self.assertRaisesRegex(
                SOURCE.SourceProvenanceError,
                "angle_enable_metal=true",
            ):
                PROMOTION.validate_report_binding(
                    candidate_path,
                    provenance,
                    args_gn,
                    report,
                    project_root=PROJECT_ROOT,
                )

    def test_copied_metal_args_cannot_promote(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_path, provenance, _ = self.write_candidate(root)
            copied_args = root / "copied-args.gn"
            copied_args.write_text(
                'target_cpu = "arm64"\nangle_enable_metal = true\n',
                encoding="utf-8",
            )
            report = root / "runtime-report.json"
            SOURCE.atomic_write_json(report, {})
            with self.assertRaisesRegex(
                SOURCE.SourceProvenanceError,
                "canonical build-root",
            ):
                PROMOTION.validate_report_binding(
                    candidate_path,
                    provenance,
                    copied_args,
                    report,
                    project_root=PROJECT_ROOT,
                )


if __name__ == "__main__":
    unittest.main()
