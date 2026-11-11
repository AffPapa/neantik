"""Exercise the .79 evidence route without manufacturing project build receipts."""

from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import chromium_15779_source as m15779
from runtime_candidate_lock import expected_candidate_lock, verify_candidate_lock
from runtime_source_provenance import SourceProvenanceError, verify_document, verify_runtime_lock_for_new_candidate


def load_script(name):
    spec = spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = module_from_spec(spec)
    with patch.dict(sys.modules, {spec.name: module}):
        spec.loader.exec_module(module)
    return module


class Chromium15779SourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.runtime = self.root / "runtime"
        for name in (m15779.CONTRACT, m15779.PLAN, "licenses/Chromium-LICENSE", "licenses/fingerprint-chromium-LICENSE",
                     "security-baseline.json", "nevision-patches/series.json", "apple-device-tuples.json"):
            target = self.runtime / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SCRIPTS.parent / "runtime" / name, target)
        self.provenance = self.root / "source-provenance.json"
        self.lock = self.root / "candidate-lock.json"

    def complete(self):
        source, upstream = m15779.SOURCE, m15779.UPSTREAM
        evidence = {
            "schemaVersion": 1,
            "status": "chromium-source-build-succeeded-unqualified",
            "chromiumVersion": m15779.VERSION,
            "targetArchitecture": "arm64",
            "officialCommit": upstream["commit"],
            "officialTree": upstream["tree"],
            "portHead": source["head"],
            "portTree": source["tree"],
            "sourcePatchSHA256": source["sourcePatchSHA256"],
            "buildConfigurationSHA256": source["buildArgsSHA256"],
            "buildOutputDirectory": source["buildOutputDirectory"],
            "ninjaTarget": "chrome",
            "ninjaExitCode": 0,
            "ninjaActionsCompleted": 7,
            "ninjaActionsExpected": 7,
            "buildLogSHA256": "a" * 64,
            "ninjaLogSHA256": "b" * 64,
            "browserExecutableSHA256": "c" * 64,
            "frameworkSHA256": "d" * 64,
            "releaseReady": False,
        }
        evidence_path = self.runtime / m15779.BUILD_EVIDENCE
        evidence_path.write_text(json.dumps(evidence))
        path = self.runtime / m15779.CONTRACT
        contract = json.loads(path.read_text())
        contract.update(
            status="build-complete-runtime-report-pending",
            binaryBindingStatus="pending-runtime-report",
            buildEvidenceFile=f"runtime/{m15779.BUILD_EVIDENCE}",
            buildEvidenceSHA256=m15779._sha256(evidence_path),
            securityBaselineSHA256=m15779._sha256(self.runtime / "security-baseline.json"),
        )
        path.write_text(json.dumps(contract))
        return evidence

    def test_pending_build_cannot_produce_a_lock(self):
        self.provenance.write_text(json.dumps({"targetChromiumVersion": m15779.VERSION}))
        with self.assertRaisesRegex(SourceProvenanceError, "awaits exact completed build evidence"):
            expected_candidate_lock(self.provenance, project_root=self.root)

    def test_completed_source_evidence_and_lock_routes(self):
        evidence = self.complete()
        contract = m15779.verify_contract(self.root)
        doc = m15779._provenance(contract, evidence, self.root)
        verify_document(doc, project_root=self.root)
        self.provenance.write_text(json.dumps(doc))
        lock = expected_candidate_lock(self.provenance, project_root=self.root)
        self.lock.write_text(json.dumps(lock))
        verify_runtime_lock_for_new_candidate(self.lock, project_root=self.root)
        self.assertEqual(verify_candidate_lock(self.lock, self.provenance, project_root=self.root), lock)
        lock["ownedInputs"]["buildArgsSHA256"] = "e" * 64
        self.lock.write_text(json.dumps(lock))
        with self.assertRaisesRegex(SourceProvenanceError, "stale or mutated"):
            verify_candidate_lock(self.lock, self.provenance, project_root=self.root)

    def test_incomplete_ninja_evidence_cannot_be_pinned(self):
        evidence = self.complete()
        evidence["ninjaActionsCompleted"] -= 1
        evidence_path = self.runtime / m15779.BUILD_EVIDENCE
        evidence_path.write_text(json.dumps(evidence))
        path = self.runtime / m15779.CONTRACT
        contract = json.loads(path.read_text())
        contract["buildEvidenceSHA256"] = m15779._sha256(evidence_path)
        path.write_text(json.dumps(contract))
        with self.assertRaisesRegex(ValueError, "completed build evidence is invalid"):
            m15779.verify_contract(self.root)

    def test_packaged_evidence_and_notices_select_exact_79_contract(self):
        evidence = self.complete()
        contract = m15779.verify_contract(self.root)
        self.provenance.write_text(json.dumps(m15779._provenance(contract, evidence, self.root)))
        lock = expected_candidate_lock(self.provenance, project_root=self.root)
        self.lock.write_text(json.dumps(lock))
        notices = load_script("generate-runtime-integration-notices")
        rendered = notices.render_m154_notices(
            project_root=self.root, runtime_lock=self.lock, source_provenance=self.provenance)
        self.assertIn(m15779.UPSTREAM["commit"], rendered)
        self.assertIn(m15779.SOURCE["sourcePatchSHA256"], rendered)
        report = load_script("verify-packaged-runtime-report")
        gui = load_script("verify-gui-fingerprint-report")
        packaged = self.root / "NeAntikRuntimeEvidence"
        self.assertEqual(report.source_evidence_paths(m15779.VERSION, packaged, self.root)[1],
                         packaged / m15779.CONTRACT)
        self.assertEqual(gui.source_contract_name(m15779.VERSION, lock), m15779.CONTRACT)
        with self.assertRaises(gui.FingerprintReportError):
            gui.source_contract_name("157.0.8103.39", lock)
