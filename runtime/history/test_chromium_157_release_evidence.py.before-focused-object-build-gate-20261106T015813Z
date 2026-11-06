import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "chromium_157_release_evidence.py"
SPEC = importlib.util.spec_from_file_location("chromium_157_release_evidence_tested", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Chromium157ReleaseEvidenceTests(unittest.TestCase):
    def test_source_contract_authenticates_exact_upstream_port_and_build_args(self):
        contract = MODULE.verify_contract(PROJECT_ROOT)

        self.assertEqual(contract["targetChromiumVersion"], "157.0.8103.39")
        self.assertEqual(contract["officialChromiumBase"]["commit"], MODULE.OFFICIAL_COMMIT)
        self.assertEqual(contract["officialChromiumBase"]["tree"], MODULE.OFFICIAL_TREE)
        self.assertEqual(contract["portSource"]["head"], MODULE.PORT_HEAD)
        self.assertEqual(contract["portSource"]["sourceFileSHA256"], MODULE.PORT_SOURCE_FILE_SHA256)
        self.assertEqual(contract["portSource"]["sourcePatchManifestSHA256"], MODULE.PORT_PATCH_SHA256)
        self.assertEqual(contract["portSource"]["buildArgsPath"], MODULE.ARGS_RELATIVE_PATH)
        self.assertEqual(contract["binaryBindingStatus"], "pending-runtime-report")
        self.assertFalse(contract["releaseReady"])

    def test_provenance_binds_product_build_focused_tests_and_aggregate_blocker(self):
        with patch.object(MODULE, "verify_source_root", return_value={
            "sourceHead": MODULE.PORT_HEAD,
            "sourcePatchSHA256": MODULE.PORT_PATCH_SHA256,
            "buildArgsSHA256": MODULE.ARGS_SHA256,
            "buildOutputDirectory": "out/neantik157-port-smoke-correctargs3",
        }):
            provenance = MODULE.build_provenance(Path("/synthetic/source"), PROJECT_ROOT)
        build = provenance["buildEvidence"]
        self.assertEqual(build["ninjaTarget"], MODULE.FOCUSED_BUILD_TARGET)
        self.assertEqual(build["focusedTestObjects"], list(MODULE.FOCUSED_TEST_OBJECTS))
        self.assertEqual(build["aggregateUnitTests"]["status"], "blocked")

    def test_focused_build_gate_rejects_missing_object_or_hidden_aggregate_failure(self):
        evidence_path = PROJECT_ROOT / "runtime" / MODULE.BUILD_EVIDENCE
        evidence = MODULE._load(evidence_path, "test build evidence")
        MODULE.validate_focused_build_evidence(evidence)
        evidence["focusedTestObjects"] = evidence["focusedTestObjects"][:-1]
        with self.assertRaisesRegex(MODULE.M157EvidenceError, "incomplete or overstated"):
            MODULE.validate_focused_build_evidence(evidence)

    def test_bare_m157_provenance_or_lock_cannot_bypass_build_gate(self):
        document = {"targetChromiumVersion": MODULE.VERSION, "releaseReady": False}
        with self.assertRaisesRegex(MODULE.M157EvidenceError, "differs from pinned evidence"):
            MODULE.verify_provenance(document, PROJECT_ROOT)


if __name__ == "__main__":
    unittest.main()
