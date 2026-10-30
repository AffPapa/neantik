import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from importlib.machinery import SourceFileLoader

module_path = Path(__file__).resolve().parents[1] / "check-source-offer-supplement.py"
check_module = SourceFileLoader("source_offer_supplement", str(module_path)).load_module()


class SourceOfferSupplementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / "base"
        self.supplement = self.root / "supplement"
        self.base.mkdir()
        self.supplement.mkdir()
        self.base_manifest = self.base / "manifest.json"
        self.base_manifest.write_text('{"base":true}\n')
        self.archive = self.base / "source.tar.zst"
        self.archive.write_bytes(b"frozen source archive")
        overlay = self.supplement / "overlay" / "runtime" / "pin.json"
        overlay.parent.mkdir(parents=True)
        overlay.write_text('{"version":"156.0.8078.48"}\n')
        self.component = {
            "path": "overlay/runtime/pin.json",
            "bytes": overlay.stat().st_size,
            "sha256": hashlib.sha256(overlay.read_bytes()).hexdigest(),
        }
        self.document = {
            "schemaVersion": 1,
            "status": "DRAFT_SUPPLEMENT_TO_V246; NOT_A_COMPLETE_SOURCE_OFFER; NOT_CANDIDATE_BOUND",
            "releaseQualified": False,
            "baseOffer": {
                "offerId": "V246",
                "manifestPath": "manifest.json",
                "manifestSHA256": hashlib.sha256(self.base_manifest.read_bytes()).hexdigest(),
                "sourceArchivePath": "source.tar.zst",
                "sourceArchiveSHA256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            },
            "supplementComponents": [self.component],
        }
        self.manifest_path = self.supplement / "supplement-manifest.json"
        self.save_manifest()

    def save_manifest(self):
        self.manifest_path.write_text(json.dumps(self.document))

    def test_checks_all_component_and_base_hashes(self):
        report = check_module.verify(self.base, self.supplement)
        self.assertEqual("SUPPLEMENT_INTEGRITY_PASS; COMPLETE_SOURCE_OFFER_NOT_PROVED", report["status"])
        self.assertEqual(1, report["componentCount"])
        self.assertFalse(report["completeSourceOffer"])
        self.assertEqual("V246", report["baseOfferID"])

    def test_accepts_v382_only_when_base_manifest_binds_declared_source_archive(self):
        self.base_manifest.write_text(json.dumps({
            "currentWebKitV382FilteredModelSource": {
                "derivedArchiveSHA256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            },
        }))
        self.document["status"] = (
            "DRAFT_SUPPLEMENT_TO_V382; NOT_A_COMPLETE_SOURCE_OFFER; NOT_CANDIDATE_BOUND")
        self.document["baseOffer"]["offerId"] = "V382"
        self.document["baseOffer"]["manifestSHA256"] = hashlib.sha256(
            self.base_manifest.read_bytes()).hexdigest()
        self.save_manifest()
        self.assertEqual("V382", check_module.verify(self.base, self.supplement)["baseOfferID"])

        self.base_manifest.write_text('{"currentWebKitV382FilteredModelSource":{}}\n')
        self.document["baseOffer"]["manifestSHA256"] = hashlib.sha256(
            self.base_manifest.read_bytes()).hexdigest()
        self.save_manifest()
        with self.assertRaisesRegex(check_module.SupplementError, "does not bind"):
            check_module.verify(self.base, self.supplement)

    def test_rejects_changed_component(self):
        (self.supplement / self.component["path"]).write_text("changed")
        with self.assertRaisesRegex(check_module.SupplementError, "hash/size mismatch"):
            check_module.verify(self.base, self.supplement)

    def test_rejects_changed_frozen_base(self):
        self.archive.write_bytes(b"changed")
        with self.assertRaisesRegex(check_module.SupplementError, "base source archive hash mismatch"):
            check_module.verify(self.base, self.supplement)

    def test_rejects_path_traversal(self):
        self.document["supplementComponents"][0]["path"] = "overlay/../outside"
        self.save_manifest()
        with self.assertRaisesRegex(check_module.SupplementError, "unsafe relative path"):
            check_module.verify(self.base, self.supplement)


if __name__ == "__main__":
    unittest.main()
