import copy
import json
import tempfile
import unittest
from pathlib import Path
import sys


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
import runtime_source_provenance as MODULE  # noqa: E402


class RuntimeSourceProvenanceTests(unittest.TestCase):
    def write_json(self, path: Path, value: dict) -> None:
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def contract(self) -> dict:
        return json.loads(
            (
                PROJECT_ROOT
                / "runtime"
                / "chromium-152-source-contract.json"
            ).read_text(encoding="utf-8")
        )

    def plan(self) -> dict:
        return json.loads(
            (
                PROJECT_ROOT
                / "runtime"
                / "chromium-152-rebase-plan.json"
            ).read_text(encoding="utf-8")
        )

    def coherent_candidate_lock(self) -> dict:
        contract = self.contract()
        return {
            "schemaVersion": 4,
            "sourceContractSHA256": MODULE.sha256_file(
                PROJECT_ROOT
                / "runtime"
                / "chromium-152-source-contract.json"
            ),
            "fingerprintChromium": {
                "chromiumVersion": contract["targetChromiumVersion"],
                "repository":
                    contract["officialChromiumBase"]["repository"],
                "tag": contract["officialChromiumBase"]["tag"],
                "commit": contract["officialChromiumBase"]["commit"],
                "tree": contract["officialChromiumBase"]["tree"],
            },
            "macPackaging": {
                "commit": contract["macPackaging"]["commit"],
                "tree": contract["macPackaging"]["tree"],
                "criticalFiles":
                    contract["macPackaging"]["criticalFiles"],
            },
            "commonChromium": {
                "tag": contract["commonChromium"]["tag"],
                "commit": contract["commonChromium"]["commit"],
                "tree": contract["commonChromium"]["tree"],
                "criticalFiles":
                    contract["commonChromium"]["criticalFiles"],
            },
        }

    def test_checked_contract_is_source_only_and_cross_checked(self) -> None:
        contract = MODULE.verify_contract(project_root=PROJECT_ROOT)

        self.assertEqual(
            contract["binaryBindingStatus"],
            "pending-new-build",
        )
        self.assertEqual(
            contract["macPackaging"]["commit"],
            "4eaad8b10b3c692d4197d05adf51f00145edf0b3",
        )
        self.assertNotIn("tag", contract["macPackaging"])
        self.assertEqual(
            contract["commonChromium"]["commit"],
            "59657a38437d11520a68618008eb825721319b9e",
        )

    def test_rejects_stale_chromium_144_mac_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "contract.json"
            contract = self.contract()
            contract["macPackaging"]["commit"] = (
                "6bbb0dbdeae887af207c75c9e5173cceddbd381b"
            )
            self.write_json(path, contract)

            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "stale Chromium 144",
            ):
                MODULE.verify_contract(
                    project_root=PROJECT_ROOT,
                    contract_path=path,
                )

    def test_rejects_invented_mac_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "contract.json"
            contract = self.contract()
            contract["macPackaging"]["tag"] = "151.0.7922.71"
            self.write_json(path, contract)

            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "must not invent",
            ):
                MODULE.verify_contract(
                    project_root=PROJECT_ROOT,
                    contract_path=path,
                )

    def test_rejects_rebase_plan_commit_drift_even_with_new_plan_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan_path = root / "plan.json"
            contract_path = root / "contract.json"
            plan = self.plan()
            plan["commonChromium"]["commit"] = "a" * 40
            self.write_json(plan_path, plan)
            contract = self.contract()
            contract["rebasePlanSHA256"] = MODULE.sha256_file(plan_path)
            self.write_json(contract_path, contract)

            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "commonChromium.commit does not match rebase plan",
            ):
                MODULE.verify_contract(
                    project_root=PROJECT_ROOT,
                    contract_path=contract_path,
                    rebase_plan_path=plan_path,
                )

    def test_rejects_owned_input_hash_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "contract.json"
            contract = self.contract()
            contract["ownedInputs"][
                "runtime/apple-device-tuples.json"
            ] = "0" * 64
            self.write_json(path, contract)

            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "Owned provenance input hash mismatch",
            ):
                MODULE.verify_contract(
                    project_root=PROJECT_ROOT,
                    contract_path=path,
                )

    def test_rejects_source_version_override_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan_path = root / "plan.json"
            contract_path = root / "contract.json"
            plan = self.plan()
            self.write_json(plan_path, plan)
            contract = self.contract()
            contract["sourceVersionOverride"]["from"] = "9.9.9.9"
            contract["sourceVersionOverride"]["to"] = "8.8.8.8"
            contract["rebasePlanSHA256"] = MODULE.sha256_file(plan_path)
            self.write_json(contract_path, contract)

            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "sourceVersionOverride does not match rebase plan",
            ):
                MODULE.verify_contract(
                    project_root=PROJECT_ROOT,
                    contract_path=contract_path,
                    rebase_plan_path=plan_path,
                )

    def test_emitted_document_rejects_tree_mutation(self) -> None:
        document = MODULE.expected_static_document(
            project_root=PROJECT_ROOT
        )
        document["sourceChecks"] = {
            "chromiumVersion": "verified",
            "officialArchiveSHA256": "verified",
            "macGitObjects": "verified",
            "commonGitObjects": "verified",
            "ownedPatchset": "already-applied",
            "ownedAppleDeviceTuples": "verified",
        }
        MODULE.verify_document(document, project_root=PROJECT_ROOT)

        changed = copy.deepcopy(document)
        changed["commonChromium"]["tree"] = "b" * 40
        with self.assertRaisesRegex(
            MODULE.SourceProvenanceError,
            "commonChromium.tree",
        ):
            MODULE.verify_document(changed, project_root=PROJECT_ROOT)

    def test_new_candidate_lock_requires_contract_and_exact_source_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "runtime-lock.json"
            self.write_json(path, self.coherent_candidate_lock())
            MODULE.verify_runtime_lock_for_new_candidate(
                path,
                project_root=PROJECT_ROOT,
            )

            changed = self.coherent_candidate_lock()
            changed["commonChromium"]["tree"] = "c" * 40
            self.write_json(path, changed)
            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "commonChromium.tree",
            ):
                MODULE.verify_runtime_lock_for_new_candidate(
                    path,
                    project_root=PROJECT_ROOT,
                )

            changed = self.coherent_candidate_lock()
            changed["fingerprintChromium"]["patchSeriesSHA256"] = "d" * 64
            self.write_json(path, changed)
            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "legacy fingerprintChromium",
            ):
                MODULE.verify_runtime_lock_for_new_candidate(
                    path,
                    project_root=PROJECT_ROOT,
                )

    def test_published_legacy_lock_remains_release_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "legacy-runtime-lock.json"
            legacy = self.coherent_candidate_lock()
            legacy["schemaVersion"] = 3
            self.write_json(path, legacy)

            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "source-contract schema 4",
            ):
                MODULE.verify_runtime_lock_for_new_candidate(
                    path,
                    project_root=PROJECT_ROOT,
                )

    def test_atomic_writer_refuses_symlink_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.json"
            target.write_text("{}\n", encoding="utf-8")
            output = root / "source-provenance.json"
            output.symlink_to(target)

            with self.assertRaisesRegex(
                MODULE.SourceProvenanceError,
                "symlinked",
            ):
                MODULE.atomic_write_json(output, {"schemaVersion": 1})


if __name__ == "__main__":
    unittest.main()
