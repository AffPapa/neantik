import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "assemble-webkit-cmake-notice-candidate.py"
SPEC = importlib.util.spec_from_file_location("webkit_notice_candidate", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class WebKitCMakeNoticeCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "upstream"
        self.source.mkdir()
        self.receipt = self.root / "receipt.json"
        self.data = b"example license\n"
        (self.source / "LICENSE").write_bytes(self.data)
        self.receipt.write_text(json.dumps({
            "upstreamCommit": MODULE.EXPECTED_COMMIT,
            "noticeFiles": [{
                "sourcePath": "LICENSE",
                "sha256": MODULE.sha256(self.data),
                "bytes": len(self.data),
                "scope": ["direct object"],
            }],
        }))

    def tearDown(self):
        self.temporary.cleanup()

    def test_collects_hash_bound_regular_notice(self):
        notices = MODULE.collect_notices(
            source_root=self.source,
            receipt_paths=(self.receipt,),
            upstream_commit=MODULE.EXPECTED_COMMIT,
        )
        self.assertEqual(notices[0]["sourcePath"], "LICENSE")
        self.assertEqual(notices[0]["sha256"], MODULE.sha256(self.data))

    def test_preserves_distinct_source_paths_with_identical_notice_bytes(self):
        second_path = "third_party/PATENTS"
        second_data = self.source / second_path
        second_data.parent.mkdir()
        second_data.write_bytes(self.data)
        second_receipt = self.root / "second-receipt.json"
        second_receipt.write_text(json.dumps({
            "upstreamCommit": MODULE.EXPECTED_COMMIT,
            "noticeFiles": [{
                "sourcePath": second_path,
                "sha256": MODULE.sha256(self.data),
                "bytes": len(self.data),
                "scope": ["selected archive:example.a"],
            }],
        }))
        notices = MODULE.collect_notices(
            source_root=self.source,
            receipt_paths=(self.receipt, second_receipt),
            upstream_commit=MODULE.EXPECTED_COMMIT,
        )
        self.assertEqual({item["sourcePath"] for item in notices}, {"LICENSE", second_path})
        self.assertEqual({item["sha256"] for item in notices}, {MODULE.sha256(self.data)})

    def test_rejects_receipt_hash_mismatch(self):
        data = json.loads(self.receipt.read_text())
        data["noticeFiles"][0]["sha256"] = "0" * 64
        self.receipt.write_text(json.dumps(data))
        with self.assertRaisesRegex(MODULE.CandidateError, "SHA-256 mismatch"):
            MODULE.collect_notices(
                source_root=self.source,
                receipt_paths=(self.receipt,),
                upstream_commit=MODULE.EXPECTED_COMMIT,
            )

    def test_rejects_symlinked_notice(self):
        outside = self.root / "outside-license"
        outside.write_bytes(self.data)
        (self.source / "LICENSE").unlink()
        (self.source / "LICENSE").symlink_to(outside)
        with self.assertRaisesRegex(MODULE.CandidateError, "regular file"):
            MODULE.collect_notices(
                source_root=self.source,
                receipt_paths=(self.receipt,),
                upstream_commit=MODULE.EXPECTED_COMMIT,
            )

    def test_rejects_path_traversal(self):
        with self.assertRaisesRegex(MODULE.CandidateError, "unsafe notice sourcePath"):
            MODULE.safe_source_path("../outside")

    def test_source_group_coverage_requires_every_pinned_notice(self):
        coverage = self.root / "source-map.json"
        coverage.write_text(json.dumps({
            "upstreamCommit": MODULE.EXPECTED_COMMIT,
            "sourceLicenseGroups": [{
                "sourceDirectory": "Source/ThirdParty/example",
                "noticeFiles": ["LICENSE"],
            }],
        }))
        covered = [{"sourcePath": "Source/ThirdParty/example/LICENSE"}]
        result = MODULE.validate_source_group_coverage(
            coverage_receipt=coverage,
            notices=covered,
            upstream_commit=MODULE.EXPECTED_COMMIT,
        )
        self.assertEqual(result["requiredNoticePaths"], 1)
        with self.assertRaisesRegex(MODULE.CandidateError, "omits source group notices"):
            MODULE.validate_source_group_coverage(
                coverage_receipt=coverage,
                notices=[],
                upstream_commit=MODULE.EXPECTED_COMMIT,
            )

    def test_resolves_extra_receipt_only_inside_repo(self):
        receipt = self.root / "extra.json"
        receipt.write_text("{}")
        self.assertEqual(
            MODULE.resolve_extra_receipts([receipt], root=self.root),
            (receipt.resolve(),),
        )
        with self.assertRaisesRegex(MODULE.CandidateError, "inside the repository"):
            MODULE.resolve_extra_receipts([Path(__file__).resolve()], root=self.root)

    def test_rejects_symlinked_extra_receipt(self):
        receipt = self.root / "extra.json"
        receipt.write_text("{}")
        link = self.root / "linked.json"
        link.symlink_to(receipt)
        with self.assertRaisesRegex(MODULE.CandidateError, "missing or unsafe"):
            MODULE.resolve_extra_receipts([link], root=self.root)


if __name__ == "__main__":
    unittest.main()
