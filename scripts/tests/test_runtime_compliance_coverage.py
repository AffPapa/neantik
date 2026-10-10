import unittest
from runtime_compliance_coverage import verify_coverage


class CoverageTests(unittest.TestCase):
    def fixture(self):
        html = '<div class="product"><span class="title">Library</span><pre>License &amp; terms</pre></div>'
        spdx = {"packages": [{"name": "Library", "licenseConcluded": "L"}] * 2,
                "hasExtractedLicensingInfos": [{"licenseId": "L", "extractedText": "License & terms"}]}
        return html, spdx

    def test_deduplicated_notices_cover_every_package(self):
        self.assertEqual(verify_coverage(*self.fixture()), 1)

    def test_removed_changed_and_unmatched_notices_fail(self):
        html, spdx = self.fixture()
        for bad in ("", html.replace("terms", "changed"), html + html.replace("Library", "Other")):
            with self.subTest(html=bad), self.assertRaises(ValueError):
                verify_coverage(bad, spdx)

    def test_missing_empty_duplicate_and_orphan_license_fail(self):
        for mode in ("missing", "empty", "duplicate", "orphan"):
            html, spdx = self.fixture()
            licenses = spdx["hasExtractedLicensingInfos"]
            if mode == "missing": licenses.clear()
            if mode == "empty": licenses[0]["extractedText"] = ""
            if mode == "duplicate": licenses.append(licenses[0].copy())
            if mode == "orphan": licenses.append({"licenseId": "other", "extractedText": "Other"})
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                verify_coverage(html, spdx)
