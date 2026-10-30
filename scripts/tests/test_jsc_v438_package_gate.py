import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "package-owned-webkit-release.py"
SPEC = importlib.util.spec_from_file_location("jsc_v438_package_gate", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class JSCV438PackageGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.review = self.root / MODULE.V438_JSC_REVIEW_PATH
        self.review.parent.mkdir()
        shutil.copyfile(MODULE.V438_JSC_REVIEW_SOURCE, self.review)
        self.binding = {"path": MODULE.V438_JSC_REVIEW_PATH.as_posix(),
                        "sha256": MODULE.V438_JSC_REVIEW_SHA256}
        self.manifest = {"currentJavaScriptCoreV438PortableReview": self.binding.copy(),
                         "sourceOfferComponents": [{**self.binding, "bytes": self.review.stat().st_size,
                                                    "includedInOfferFolder": True}]}

    def write_manifest(self):
        data = (json.dumps(self.manifest, sort_keys=True) + "\n").encode()
        (self.root / "manifest.json").write_bytes(data)
        return hashlib.sha256(data).hexdigest()

    def test_exact_review_passes_and_missing_binding_fails(self):
        MODULE.verify_v438_jsc_review(self.root, self.write_manifest())
        del self.manifest["currentJavaScriptCoreV438PortableReview"]
        with self.assertRaises(MODULE.PackageError):
            MODULE.verify_v438_jsc_review(self.root, self.write_manifest())

    def test_tampered_or_symlinked_review_fails(self):
        digest = self.write_manifest()
        self.review.write_text("tampered")
        with self.assertRaises(MODULE.PackageError):
            MODULE.verify_v438_jsc_review(self.root, digest)
        self.review.unlink()
        self.review.symlink_to(MODULE.V438_JSC_REVIEW_SOURCE)
        with self.assertRaises(MODULE.PackageError):
            MODULE.verify_v438_jsc_review(self.root, digest)

    def test_unbound_manifest_and_duplicate_rows_fail(self):
        digest = self.write_manifest()
        with self.assertRaises(MODULE.PackageError):
            MODULE.verify_v438_jsc_review(self.root, "0" * 64)
        self.manifest["sourceOfferComponents"].append(self.manifest["sourceOfferComponents"][0])
        with self.assertRaises(MODULE.PackageError):
            MODULE.verify_v438_jsc_review(self.root, self.write_manifest())


if __name__ == "__main__":
    unittest.main()
