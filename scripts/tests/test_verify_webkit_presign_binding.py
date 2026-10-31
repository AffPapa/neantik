import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "presign_binding", Path(__file__).resolve().parents[1] / "verify-webkit-presign-binding.py")
binding = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(binding)


class PresignBindingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.build = self.root / "build"
        self.stage = self.root / "stage"
        self.evidence = self.root / "evidence"
        for path in (self.build, self.stage, self.evidence):
            path.mkdir()
        self.evidence.joinpath("review.json").write_text("review")
        self.rows = []
        self.images = []
        for i in range(14):
            data = f"runtime image {i}".encode()
            name = f"image-{i}"
            self.build.joinpath(name).write_bytes(data)
            self.stage.joinpath(name).write_bytes(data)
            sha = hashlib.sha256(data).hexdigest()
            self.rows.append({"path": name, "sha256": sha, "bytes": len(data)})
            self.images.append({"path": name, "sha256": sha, "bytes": len(data),
                                "rebuildOutputsWithSameBytes": [name],
                                "compatibilitySpanSeparateInput": False})
        data = self.stage.joinpath("image-0").read_bytes()
        self.stage.joinpath("duplicate").write_bytes(data)
        self.images.append({"path": "duplicate", "sha256": binding.digest(self.stage / "duplicate"),
                            "bytes": len(data), "rebuildOutputsWithSameBytes": ["image-0"],
                            "compatibilitySpanSeparateInput": False})
        data = b"compatibility"
        self.stage.joinpath("libswiftCompatibilitySpan.dylib").write_bytes(data)
        self.images.append({"path": "libswiftCompatibilitySpan.dylib",
                            "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
                            "rebuildOutputsWithSameBytes": [], "compatibilitySpanSeparateInput": True})
        components = []
        for name in ("source", "patch", "resource", "manager-archive"):
            file = self.root / name
            file.write_bytes(name.encode())
            components.append({"path": name, "sha256": binding.digest(file),
                               "bytes": file.stat().st_size, "includedInOfferFolder": True})
        pins = {item["path"]: item["sha256"] for item in components}
        self.build_receipt = self.write("build.json", {"inputs": {
            "webkitCommit": "commit", "sourceArchiveSHA256": pins["source"],
            "mainSourcePatchSHA256": pins["patch"], "v36PatchSHA256": pins["resource"]}, "outputs": self.rows})
        self.stage_receipt = self.write("stage.json", {
            "machOSHA256": {x["path"]: x["sha256"] for x in self.images}})
        self.offer = self.write("offer.json", {"source": {"commit": "manager",
            "sourceArchiveSHA256": pins["manager-archive"]}, "sourceOfferComponents": components})
        self.draft = {"schemaVersion": 1, "releaseQualified": False,
            "noticeEvidenceIsComplete": False, "productionV122PinsModified": False,
            "buildReceiptSHA256": binding.digest(self.build_receipt),
            "stagingReceiptSHA256": binding.digest(self.stage_receipt),
            "sourceOfferManifestSHA256": binding.digest(self.offer),
            "managerSourceCommit": "manager", "webkitUpstreamCommit": "commit",
            "webkitSourceArchiveSHA256": pins["source"], "mainPatchSHA256": pins["patch"],
            "resourcePatchSHA256": pins["resource"], "matchingRebuildOutputs": 14,
            "stagedImagesCount": 16, "stagedImages": self.images,
            "sourceEvidence": {"review.json": binding.digest(self.evidence / "review.json")},
            "partialImageNoticeEvidence": [{"imagePaths": ["image-0"],
                                             "sourceEvidence": ["review.json"]}]}
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, data):
        path = self.root / name
        path.write_text(json.dumps(data))
        return path

    def check(self):
        path = self.write("draft.json", self.draft)
        return binding.verify(path, binding.digest(path), self.build, self.stage,
                              self.build_receipt, self.stage_receipt, self.offer, self.evidence)

    def test_valid_presign_binding(self):
        self.assertFalse(self.check()["releaseQualified"])

    def test_changed_staged_image_is_refused(self):
        self.stage.joinpath("image-0").write_bytes(b"changed")
        with self.assertRaises(binding.BindingError):
            self.check()

    def test_missing_evidence_and_unsafe_paths_are_refused(self):
        self.draft["sourceEvidence"] = {"../outside": "x"}
        with self.assertRaises(binding.BindingError):
            self.check()

    def test_unbound_rebuild_output_is_refused(self):
        self.images[0]["rebuildOutputsWithSameBytes"] = ["image-1"]
        with self.assertRaises(binding.BindingError):
            self.check()

    def test_changed_source_archive_is_refused(self):
        self.root.joinpath("source").write_bytes(b"changed")
        with self.assertRaises(binding.BindingError):
            self.check()

    def test_symlinked_image_is_refused(self):
        image = self.stage / "image-0"
        image.unlink()
        image.symlink_to(self.build / "image-0")
        with self.assertRaises(binding.BindingError):
            self.check()


if __name__ == "__main__":
    unittest.main()
