import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
PROJECT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

from chromium_15498_release_evidence import (
    COMPATIBILITY_TARGETS,
    COMMIT,
    TREE,
    VERSION,
    EVIDENCE_NAMES,
    M15498EvidenceError,
    verify_candidate_document,
    verify_candidate_lock,
    verify_contract,
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class M15498EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)
        self.runtime = self.project / "runtime"
        self.runtime.mkdir()
        self.evidence = self.runtime / "chromium-15498-source-evidence"
        self.evidence.mkdir()
        for name in EVIDENCE_NAMES:
            shutil.copy2(PROJECT / "runtime/chromium-15498-source-evidence" / name,
                         self.evidence / name)
        patches = self.runtime / "nevision-patches/ports/chromium-154.0.8037.98/patches"
        patches.mkdir(parents=True)
        source_patches = PROJECT / "runtime/nevision-patches/ports/chromium-154.0.8037.98/patches"
        for name in COMPATIBILITY_TARGETS:
            shutil.copy2(source_patches / name, patches / name)
        shutil.copytree(
            PROJECT / "runtime/nevision-patches/ports/chromium-154.0.8037.93/patches",
            self.runtime / "nevision-patches/ports/chromium-154.0.8037.93/patches",
        )
        (self.project / "scripts").mkdir()
        for name in ("replay-chromium-15498.py", "apply-owned-runtime-device-tuples-15498.py",
                     "apply-device-memory-hotfix-15498.py"):
            shutil.copy2(PROJECT / "scripts" / name, self.project / "scripts" / name)
        shutil.copy2(PROJECT / "runtime/chromium-154-rebase-plan.json",
                     self.runtime / "chromium-154-rebase-plan.json")
        for name in ("chromium-15498-toolchain-lock.json", "security-baseline.json",
                     "apple-device-tuples.json"):
            write_json(self.runtime / name, {"fixture": name})
        self.args_sha = hashlib.sha256(b"angle_enable_metal = true\n").hexdigest()
        plan = json.loads((PROJECT / "runtime/chromium-15498-rebase-plan.json").read_text())
        plan["buildPolicy"]["argsGNSHA256"] = self.args_sha
        plan["buildPolicy"]["toolchainLockSHA256"] = digest(self.runtime / "chromium-15498-toolchain-lock.json")
        write_json(self.runtime / "chromium-15498-rebase-plan.json", plan)
        snapshot = {
            "schemaVersion": 2, "recordType": "chromium-source-snapshot",
            "targetChromiumVersion": VERSION,
            "officialChromiumBase": {"commit": COMMIT, "tree": TREE},
            "argsGN": {"relativePath": "out/NeAntikM154Qualified20261006/args.gn", "sha256": self.args_sha},
            "sourceFileCount": 1_100_000, "deletedPathCount": 3000,
            "entriesSHA256": "a" * 64, "deletedPathsSHA256": "b" * 64,
            "releaseReady": False,
        }
        write_json(self.runtime / "chromium-15498-source-snapshot.json", snapshot)
        manifest = {
            "schemaVersion": 1, "chromiumVersion": VERSION,
            "status": "source-reconstructed", "sourceInputsReady": True,
            "releaseReady": False, "sourceSnapshotSHA256": digest(self.runtime / "chromium-15498-source-snapshot.json"),
            "buildArgsSHA256": self.args_sha,
            "evidence": [{"path": name, "sha256": digest(self.evidence / name)} for name in EVIDENCE_NAMES],
        }
        write_json(self.runtime / "chromium-15498-source-input-manifest.json", manifest)
        contract = {
            "schemaVersion": 2, "status": "source-qualified", "releaseReady": False,
            "targetChromiumVersion": VERSION, "targetArchitecture": "arm64",
            "sourceMode": "official-chromium-owned-macos-port",
            "safeBrowsingMode": 0, "enterpriseCloudContentAnalysis": True,
            "officialChromiumBase": {"commit": COMMIT, "tree": TREE},
            "buildArgsSHA256": self.args_sha,
            "sourceSnapshotSHA256": manifest["sourceSnapshotSHA256"],
            "sourceInputManifestSHA256": digest(self.runtime / "chromium-15498-source-input-manifest.json"),
            "toolchainLockSHA256": digest(self.runtime / "chromium-15498-toolchain-lock.json"),
            "securityBaselineSHA256": digest(self.runtime / "security-baseline.json"),
            "appleDeviceTuplesSHA256": digest(self.runtime / "apple-device-tuples.json"),
            "rebasePlanSHA256": digest(self.runtime / "chromium-15498-rebase-plan.json"),
        }
        write_json(self.runtime / "chromium-15498-source-contract.json", contract)

    def test_exact_source_contract_passes(self):
        result, snapshot = verify_contract(self.project)
        self.assertEqual(result["targetChromiumVersion"], VERSION)
        self.assertEqual(snapshot["officialChromiumBase"]["commit"], COMMIT)

    def test_patch_tamper_fails(self):
        patch = self.runtime / "nevision-patches/ports/chromium-154.0.8037.98/patches/restore-upstream-clang-24.patch"
        patch.write_bytes(patch.read_bytes() + b"\n")
        with self.assertRaisesRegex(M15498EvidenceError, "patch digest"):
            verify_contract(self.project)

    def test_safe_browsing_binding_patch_tamper_fails(self):
        patch = self.runtime / "nevision-patches/ports/chromium-154.0.8037.98/patches/bind-safe-browsing-pref-header.patch"
        patch.write_bytes(patch.read_bytes() + b"\n")
        with self.assertRaisesRegex(M15498EvidenceError, "patch digest"):
            verify_contract(self.project)

    def test_owned_patch_tamper_fails(self):
        patch = self.runtime / "nevision-patches/ports/chromium-154.0.8037.93/patches/profile-seed-contract.patch"
        patch.write_bytes(patch.read_bytes() + b"\n")
        with self.assertRaisesRegex(M15498EvidenceError, "owned patch bytes"):
            verify_contract(self.project)

    def test_unreviewed_evidence_fails(self):
        write_json(self.evidence / "extra.json", {"unexpected": True})
        with self.assertRaisesRegex(M15498EvidenceError, "extra files"):
            verify_contract(self.project)

    def test_candidate_rejects_mixed_source_contract(self):
        candidate = {
            "schemaVersion": 1, "status": "candidate-bound", "releaseReady": False,
            "targetChromiumVersion": VERSION, "targetArchitecture": "arm64",
            "sourceContractSHA256": "0" * 64,
            "sourceInputManifestSHA256": "0" * 64,
            "sourceSnapshotSHA256": "0" * 64,
            "binaryBinding": {"status": "bound-to-built-candidate", "sourceVersion": VERSION,
                              "architecture": "arm64", "argsGNSHA256": self.args_sha,
                              "candidateExecutableSHA256": "1" * 64,
                              "candidateFrameworkSHA256": "2" * 64},
        }
        write_json(self.runtime / "chromium-15498-port-candidate.json", candidate)
        with self.assertRaisesRegex(M15498EvidenceError, "source binding"):
            verify_candidate_document(candidate, project_root=self.project)

    def test_verified_tuple_lock_requires_coherent_http_and_js(self):
        candidate = {
            "schemaVersion": 1, "status": "candidate-bound", "releaseReady": False,
            "targetChromiumVersion": VERSION, "targetArchitecture": "arm64",
            "sourceContractSHA256": digest(self.runtime / "chromium-15498-source-contract.json"),
            "sourceInputManifestSHA256": digest(self.runtime / "chromium-15498-source-input-manifest.json"),
            "sourceSnapshotSHA256": digest(self.runtime / "chromium-15498-source-snapshot.json"),
            "binaryBinding": {"status": "bound-to-built-candidate", "sourceVersion": VERSION,
                              "architecture": "arm64", "argsGNSHA256": self.args_sha,
                              "candidateExecutableSHA256": "1" * 64,
                              "candidateFrameworkSHA256": "2" * 64},
        }
        write_json(self.runtime / "chromium-15498-port-candidate.json", candidate)
        qualification_path = self.evidence / "coherent-apple-device-tuples-runtime-qualification.json"
        qualification = {
            "schemaVersion": 1, "status": "verified", "releaseReady": False,
            "chromiumVersion": VERSION, "guiProductionQualified": True,
            "sourceCandidateSHA256": digest(self.runtime / "chromium-15498-port-candidate.json"),
            "tupleCatalogSHA256": digest(self.runtime / "apple-device-tuples.json"),
            "unsignedFrameworkSHA256": "2" * 64,
            "deviceMemory": {"coherent": True, "js": 8,
                             "navigation": {"modern": "8", "legacy": "8"},
                             "subresource": {"modern": "8", "legacy": "8"}},
        }
        for key in ("signedRuntimeExecutableSHA256", "signedRuntimeFrameworkSHA256",
                    "candidateManifestSHA256", "authenticatedGUIEnvelopeSHA256",
                    "publicSafeGUISummarySHA256"):
            qualification[key] = "3" * 64
        write_json(qualification_path, qualification)
        lock = {
            "schemaVersion": 4, "status": "source-qualified", "releaseReady": False,
            "targetArchitecture": "arm64",
            "fingerprintChromium": {"chromiumVersion": VERSION, "commit": COMMIT, "tree": TREE},
            "sourceContractSHA256": candidate["sourceContractSHA256"],
            "sourceProvenanceSHA256": digest(self.runtime / "chromium-15498-port-candidate.json"),
            "verification": {
                "coherentAppleDeviceTuples": "verified",
                "coherentAppleDeviceTuplesEvidence": "runtime/chromium-15498-source-evidence/coherent-apple-device-tuples-runtime-qualification.json",
                "coherentAppleDeviceTuplesEvidenceSHA256": digest(qualification_path),
            },
        }
        write_json(self.runtime / "fingerprint-chromium-15498.lock.json", lock)
        verify_candidate_lock(lock, provenance=candidate, project_root=self.project)
        qualification["deviceMemory"]["subresource"]["legacy"] = "32"
        write_json(qualification_path, qualification)
        lock["verification"]["coherentAppleDeviceTuplesEvidenceSHA256"] = digest(qualification_path)
        write_json(self.runtime / "fingerprint-chromium-15498.lock.json", lock)
        with self.assertRaisesRegex(M15498EvidenceError, "subresource Device Memory"):
            verify_candidate_lock(lock, provenance=candidate, project_root=self.project)


if __name__ == "__main__":
    unittest.main()
