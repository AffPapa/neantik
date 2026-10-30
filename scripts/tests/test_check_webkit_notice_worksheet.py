import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check-webkit-notice-worksheet.py"
SPEC = importlib.util.spec_from_file_location("notice_worksheet_check", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NoticeWorksheetCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = self.root / "WebKit.framework/Versions/A/WebKit"
        self.file.parent.mkdir(parents=True)
        self.file.write_bytes(b"original")
        self.row = {"runtimePath": "WebKit.framework/Versions/A/WebKit",
                    "runtimeSHA256": hashlib.sha256(b"original").hexdigest(),
                    "decision": {field: "reviewed" for field in MODULE.DECISION_FIELDS}}

    def worksheet(self):
        return {"schemaVersion": 1, "images": [self.row], "resources": []}

    def test_changed_bytes_and_unresolved_decision_are_separate(self):
        self.file.write_bytes(b"changed")
        self.row["decision"]["reviewerDecision"] = "unknown"
        result = MODULE.compare(self.worksheet(), self.root, complete=False)
        self.assertEqual((result["changedCount"], result["unresolvedDecisionCount"]), (1, 1))
        self.assertEqual(result["changed"][0]["observedSHA256"], hashlib.sha256(b"changed").hexdigest())

    def test_symlink_and_traversal_are_refused(self):
        self.file.unlink()
        self.file.symlink_to(self.root / "outside")
        with self.assertRaises(MODULE.WorksheetError):
            MODULE.compare(self.worksheet(), self.root, complete=False)
        self.row["runtimePath"] = "../outside"
        with self.assertRaises(MODULE.WorksheetError):
            MODULE.compare(self.worksheet(), self.root, complete=False)

    def test_full_matrix_cannot_be_silently_truncated(self):
        with self.assertRaises(MODULE.WorksheetError):
            MODULE.compare(self.worksheet(), self.root)


if __name__ == "__main__":
    unittest.main()
