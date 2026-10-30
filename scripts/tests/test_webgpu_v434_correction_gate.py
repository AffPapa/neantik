import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "package-owned-webkit-release.py"
SPEC = importlib.util.spec_from_file_location("webgpu_v434_package_gate", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
CORRECTION = SCRIPT.parents[1] / "docs/evidence/v434-runtime-bindings/WEBGPU-V423-METADATA-CORRECTION.json"


class WebGPUV434CorrectionGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / MODULE.V434_WEBGPU_CORRECTION_PATH
        self.path.parent.mkdir(parents=True)
        shutil.copyfile(CORRECTION, self.path)
        self.manifest = {
            "currentWebGPUV423TargetRelink": {
                "receiptSHA256": MODULE.V423_WEBGPU_RECEIPT_SHA256,
                "outputSHA256": MODULE.V423_WEBGPU_OUTPUT_SHA256,
            },
            "currentWebGPUV434MetadataCorrection": {
                "path": MODULE.V434_WEBGPU_CORRECTION_PATH.as_posix(),
                "sha256": MODULE.V434_WEBGPU_CORRECTION_SHA256,
            },
            "sourceOfferComponents": [{
                "path": MODULE.V434_WEBGPU_CORRECTION_PATH.as_posix(),
                "sha256": MODULE.V434_WEBGPU_CORRECTION_SHA256,
                "bytes": self.path.stat().st_size,
                "includedInOfferFolder": True,
            }],
        }

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self):
        data = (json.dumps(self.manifest, sort_keys=True) + "\n").encode()
        (self.root / "manifest.json").write_bytes(data)
        return hashlib.sha256(data).hexdigest()

    def test_exact_v423_offer_requires_hash_pinned_v434_correction(self):
        MODULE.verify_v434_webgpu_correction(self.root, self.write_manifest())
        self.manifest.pop("currentWebGPUV434MetadataCorrection")
        with self.assertRaisesRegex(MODULE.PackageError, "correction is missing or invalid"):
            MODULE.verify_v434_webgpu_correction(self.root, self.write_manifest())

    def test_changed_or_symlinked_correction_is_refused(self):
        manifest_hash = self.write_manifest()
        self.path.write_text("tampered")
        with self.assertRaisesRegex(MODULE.PackageError, "correction is missing or invalid"):
            MODULE.verify_v434_webgpu_correction(self.root, manifest_hash)
        self.path.unlink()
        self.path.symlink_to(CORRECTION)
        with self.assertRaisesRegex(MODULE.PackageError, "correction is missing or invalid"):
            MODULE.verify_v434_webgpu_correction(self.root, manifest_hash)

    def test_other_webgpu_offer_does_not_inherit_v423_correction(self):
        self.manifest.pop("currentWebGPUV423TargetRelink")
        MODULE.verify_v434_webgpu_correction(self.root, self.write_manifest())


if __name__ == "__main__":
    unittest.main()
