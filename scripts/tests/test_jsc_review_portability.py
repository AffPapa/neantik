import hashlib
import importlib.util
import json
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "webkit_runtime_notices.py"
SPEC = importlib.util.spec_from_file_location("jsc_review_portability", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ROOT = SCRIPT.parents[1]


class JSCReviewPortabilityTests(unittest.TestCase):
    def test_review_only_replaces_local_path_and_preserves_original_binding(self):
        portable = json.loads((ROOT / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE).read_bytes())
        correction = portable["portabilityCorrection"]
        self.assertEqual(correction["originalReviewSHA256"],
                         MODULE.JSC_HEADERLESS_BSD2_ORIGINAL_REVIEW_SHA256)
        self.assertEqual(correction["changedFields"], ["licenseText.path"])
        path = portable["licenseText"]["path"]
        self.assertFalse(Path(path).is_absolute())
        self.assertNotIn("/private/tmp/", path)
        _license, review_path, review = MODULE._jsc_headerless_bsd2_sources(ROOT)
        self.assertEqual(review_path, ROOT / MODULE.JSC_HEADERLESS_BSD2_REVIEW_SOURCE)
        self.assertEqual(review["counts"]["headerlessInputs"], 32)


if __name__ == "__main__":
    unittest.main()
