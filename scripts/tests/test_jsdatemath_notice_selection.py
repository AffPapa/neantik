import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "webkit_runtime_notices.py"
SPEC = importlib.util.spec_from_file_location("jsdatemath_notice_selection", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class JSDateMathNoticeSelectionTests(unittest.TestCase):
    def test_both_notice_formats_keep_option_alternatives_and_v8_conditions(self):
        for rendered in (MODULE.render_jsc_tri_license_markdown(),
                         MODULE.render_jsc_tri_license_html()):
            self.assertIn("NeAntik applies the LGPL-2.1 option", rendered)
            self.assertIn("original alternatives remain available to recipients", rendered)
            self.assertIn("V8 BSD-style", rendered)
            self.assertIn("binary redistribution conditions", rendered)
            self.assertIn("relinking", rendered)
            self.assertNotIn("does not select a distribution option", rendered)


if __name__ == "__main__":
    unittest.main()
