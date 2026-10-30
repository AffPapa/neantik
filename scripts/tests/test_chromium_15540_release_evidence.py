"""Negative controls for the new M155 route; synthetic tests are not qualification."""
import copy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chromium_15540_release_evidence as evidence
from runtime_build_path import verify_build_args
from runtime_source_provenance import contract_paths_for_version, SourceProvenanceError


class M155EvidenceTests(unittest.TestCase):
    def test_exact_router_rejects_other_m155_versions(self):
        contract, _ = contract_paths_for_version("155.0.8059.40")
        self.assertEqual(contract.name, "chromium-15540-source-contract.json")
        for version in ("155.0.8059.26", "155.0.8059.41", "155.0.0.0"):
            with self.assertRaises(SourceProvenanceError):
                contract_paths_for_version(version)
            with self.assertRaises(ValueError):
                verify_build_args(Path("/source"), Path("/source/out/Default/args.gn"),
                                  {"fingerprintChromium": {"chromiumVersion": version}}, Path("/project"))

    def test_relative_input_guard_rejects_traversal_and_parent_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "ok").write_bytes(b"ok")
            self.assertEqual(evidence.safe_relative_regular(root, "ok"), root / "ok")
            (root / "linked").symlink_to(root, target_is_directory=True)
            for name in ("../ok", "/ok", "./ok", "linked/ok", "missing", "ok//child"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    evidence.safe_relative_regular(root, name)

    def lock_and_plan(self):
        value = "a" * 64
        plan = {
            "upstreamCommonOverlay": dict(repository="https://github.com/ungoogled-software/ungoogled-chromium.git", commit="c"*40, tree="d"*40),
            "upstreamMacPackaging": dict(repository="https://github.com/ungoogled-software/ungoogled-chromium-macos.git", commit="e"*40, tree="f"*40),
        }
        lock = dict(schemaVersion=4, status="source-qualified", releaseReady=False, targetArchitecture="arm64",
                    fingerprintChromium=dict(chromiumVersion=evidence.VERSION, commit=evidence.COMMIT, tree=evidence.TREE),
                    sourceContract=f"runtime/{evidence.PREFIX}-source-contract.json", sourceContractSHA256=value,
                    sourceProvenance=f"runtime/{evidence.PREFIX}-port-candidate.json", sourceProvenanceSHA256=value,
                    commonChromium=copy.deepcopy(plan["upstreamCommonOverlay"]),
                    macPackaging={**plan["upstreamMacPackaging"], "packagedChromiumVersion": evidence.VERSION},
                    binaryBinding=dict(requiredEvidence=f"runtime/{evidence.PREFIX}-port-candidate.json"),
                    ownedManifests=dict(securityBaselineSHA256=value), verification={})
        return lock, plan

    def verify_synthetic_lock(self, lock, plan):
        # Canonical equality is deliberately satisfied: test the independent
        # common/mac/requiredEvidence checks, which the old draft omitted.
        def read(path, label):
            return plan if path.name.endswith("rebase-plan.json") else lock
        with patch.object(evidence, "read_object", side_effect=read), \
             patch.object(evidence, "verify_candidate_document"), \
             patch.object(evidence, "bound_baseline_path", return_value=Path("/project/runtime/security-baseline.json")), \
             patch.object(evidence, "sha256_file", return_value="a"*64):
            evidence.verify_candidate_lock(lock, provenance={}, project_root=Path("/project"))

    def test_valid_upstream_binding_and_mutation_controls(self):
        lock, plan = self.lock_and_plan()
        self.verify_synthetic_lock(lock, plan)
        for field in ("commonChromium", "macPackaging"):
            changed = copy.deepcopy(lock)
            changed[field]["commit"] = "0"*40
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify_synthetic_lock(changed, plan)
        changed = copy.deepcopy(lock)
        changed["binaryBinding"]["requiredEvidence"] = "runtime/chromium-154-port-candidate.json"
        with self.assertRaises(ValueError):
            self.verify_synthetic_lock(changed, plan)

    def test_restored_types_use_exact_lock_and_reject_drift_or_traversal(self):
        import json
        report = json.loads((Path(__file__).resolve().parents[2] /
            "runtime/chromium-15540-source-evidence/pinned-build-inputs.json").read_text())["restoredBuildTypes"]
        evidence.verify_restored_build_types(report)
        for field, bad in (("version", "5.26.5"), ("archiveSHA256", "0"*64),
                           ("reference", "https://untrusted.invalid/types.tgz")):
            changed = copy.deepcopy(report)
            changed[field] = bad
            with self.subTest(field=field), self.assertRaises(ValueError):
                evidence.verify_restored_build_types(changed)
        changed = copy.deepcopy(report)
        changed["files"][0]["path"] = "third_party/node/node_modules/undici-types/../../outside.d.ts"
        with self.assertRaises(ValueError):
            evidence.verify_restored_build_types(changed)

    def test_packaged_qualified_tuple_evidence_cannot_be_removed_or_changed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            relative = f"{evidence.PREFIX}-source-evidence/coherent-apple-device-tuples-runtime-qualification.json"
            reviewed = root / "runtime" / relative
            packaged = root / "packaged" / relative
            reviewed.parent.mkdir(parents=True)
            packaged.parent.mkdir(parents=True)
            payload = b'{"syntheticQualification":"verified"}'
            reviewed.write_bytes(payload)
            packaged.write_bytes(payload)
            lock = {"verification": {"coherentAppleDeviceTuples": "verified",
                "coherentAppleDeviceTuplesEvidenceSHA256": evidence.sha256_file(reviewed)}}
            evidence.verify_packaged_tuple_qualification(root, root / "packaged", lock)
            packaged.unlink()
            with self.assertRaises(ValueError):
                evidence.verify_packaged_tuple_qualification(root, root / "packaged", lock)
            packaged.write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                evidence.verify_packaged_tuple_qualification(root, root / "packaged", lock)
            packaged.unlink()
            packaged.symlink_to(reviewed)
            with self.assertRaises(ValueError):
                evidence.verify_packaged_tuple_qualification(root, root / "packaged", lock)

    def test_live_overlay_cannot_be_rebaselined_by_new_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            (source / "out/config").mkdir(parents=True)
            (source / "overlay.cc").write_bytes(b"incorrect overlay")
            value = "a"*64
            contract = dict(sourceInputManifestSHA256=value, sourceSnapshotSHA256=value, buildArgsSHA256=value)
            snapshot = dict(argsGN=dict(relativePath="out/config/args.gn"))
            candidate = dict(schemaVersion=1, status="candidate-bound", releaseReady=False,
                targetChromiumVersion=evidence.VERSION, targetArchitecture="arm64", sourceContractSHA256=value,
                sourceInputManifestSHA256=value, sourceSnapshotSHA256=value,
                binaryBinding=dict(status="bound-to-built-candidate", sourceVersion=evidence.VERSION,
                    architecture="arm64", argsGNSHA256=value, candidateExecutableSHA256=value, candidateFrameworkSHA256=value))
            def read(path, label):
                return {"inputs": []} if path.name == "pinned-build-inputs.json" else candidate
            with patch.object(evidence, "read_object", side_effect=read), \
                 patch.object(evidence, "verify_contract", return_value=(contract, snapshot)), \
                 patch.object(evidence, "build_snapshot", return_value=snapshot), \
                 patch.object(evidence, "compact_snapshot", side_effect=lambda x: x), \
                 patch.object(evidence, "sha256_file", return_value=value), \
                 patch.object(evidence, "verify_restored_build_types"), \
                 patch.object(evidence, "final_overlay_postimages", return_value={"overlay.cc": "b"*64}):
                with self.assertRaisesRegex(ValueError, "final source postimage mismatch"):
                    evidence.verify_candidate_document(candidate, project_root=root, source_root=source)


if __name__ == "__main__":
    unittest.main()
