"""Prevent visible SwiftUI literal strings from silently falling back to Russian."""
import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("direct_ui_localization", ROOT / "scripts/verify-direct-ui-localization.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EnglishLocalizationCoverageTests(unittest.TestCase):
    def test_russian_visible_literals_have_english_translations(self):
        table = (ROOT / "Resources/en.lproj/Localizable.strings").read_text(encoding="utf-8")
        entries = re.findall(r'^("(?:\\.|[^"\\])*\")\s*=\s*("(?:\\.|[^"\\])*\");', table, re.MULTILINE)
        translations = {json.loads(key): json.loads(value) for key, value in entries}
        self.assertEqual(len(translations), len(entries), "Duplicate English localization keys")
        missing = []
        for path in (ROOT / "Sources/NeAntik").rglob("*.swift"):
            for match in MODULE.VISIBLE_CALL.finditer(path.read_text(encoding="utf-8")):
                value = match.group(1)
                try:
                    value = json.loads('"' + value + '"')
                except json.JSONDecodeError:
                    # Swift interpolation is not a JSON escape and must have an
                    # explicit localization path rather than being hidden.
                    pass
                if re.search(r"[А-Яа-яЁё]", value) and value not in translations:
                    missing.append(f"{path.name}: {value}")
        self.assertEqual(missing, [], "Visible Russian literals need English translations")


if __name__ == "__main__":
    unittest.main()
