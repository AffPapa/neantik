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


    def test_fingerprint_dynamic_verdicts_and_phases_have_english(self):
        table = (ROOT / "Resources/en.lproj/Pages.strings").read_text(encoding="utf-8")
        entries = re.findall(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', table, re.MULTILINE)
        translations = {json.loads(key): json.loads(value) for key, value in entries}
        self.assertEqual(len(translations), len(entries), "Duplicate Pages keys")
        source = (ROOT / "Sources/NeAntik/FingerprintAudit.swift").read_text(encoding="utf-8")
        verdicts = source.split("enum FingerprintAuditVerdict:", 1)[1].split("enum FingerprintAuditExecutionMode:", 1)[0]
        values = re.findall(r'"([^"\\]*[А-Яа-яЁё][^"\\]*)"', verdicts)
        self.assertEqual(len(values), 8)
        phases = re.findall(r'fingerprintPhaseText\("([^"\\]+)"\)', source)
        for key in values + phases:
            self.assertIn(key, translations, key)
            self.assertNotRegex(translations[key], r"[А-Яа-яЁё]", key)


    def test_fingerprint_view_and_preflight_strings_have_english(self):
        translations = {}
        for filename in ("Localizable.strings", "Pages.strings"):
            table = (ROOT / "Resources/en.lproj" / filename).read_text(encoding="utf-8")
            entries = re.findall(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', table, re.MULTILINE)
            translations.update({json.loads(key): json.loads(value) for key, value in entries})
        view = (ROOT / "Sources/NeAntik/FingerprintAuditView.swift").read_text(encoding="utf-8")
        preflight = (ROOT / "Sources/NeAntik/BrowserRuntimePreflight.swift").read_text(encoding="utf-8")
        values = re.findall(r'"([^"\\]*[А-Яа-яЁё][^"\\]*)"', view)
        values += re.findall(r'errors\.append\("([^"\\]+)"\)', preflight)
        # This is an internal automation log prefix, not user interface text.
        values.remove("Автоматическая проверка отпечатка остановлена: ")
        for key in values:
            self.assertIn(key, translations, key)
            self.assertNotRegex(translations[key], r"[А-Яа-яЁё]", key)


if __name__ == "__main__":
    unittest.main()
