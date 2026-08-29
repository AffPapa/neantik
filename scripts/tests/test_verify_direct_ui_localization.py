import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-direct-ui-localization.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_direct_ui_localization",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write_sources(root: Path, *, extra: str = "") -> tuple[Path, Path]:
    sources = root / "Sources"
    common = "\n".join(
        f'Button("{action}") {{}}' for action in MODULE.REQUIRED_ACTIONS
    )
    sources.mkdir(parents=True, exist_ok=True)
    (sources / "ContentView.swift").write_text(
        common,
        encoding="utf-8",
    )
    (sources / "AdditionalView.swift").write_text(
        extra,
        encoding="utf-8",
    )
    info_plist = root / "Info.plist"
    with info_plist.open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleDevelopmentRegion": "ru",
                "CFBundleLocalizations": ["ru"],
            },
            stream,
        )
    russian_resources = root / "ru.lproj"
    russian_resources.mkdir()
    (russian_resources / "InfoPlist.strings").write_text(
        '"CFBundleName" = "NeAntik";\n',
        encoding="utf-8",
    )
    (russian_resources / "Localizable.strings").write_text(
        "\n".join(
            f'"{key}" = "Перевод";'
            for key in MODULE.REQUIRED_RUSSIAN_BUNDLE_STRINGS
        ),
        encoding="utf-8",
    )
    return sources, info_plist


class VerifyDirectUiLocalizationTests(unittest.TestCase):
    def test_accepts_required_russian_actions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sources, info_plist = write_sources(Path(temporary))
            result = MODULE.inspect_sources(sources, info_plist)
        self.assertTrue(result["qualified"])
        self.assertEqual(result["bundleDevelopmentRegion"], "ru")
        self.assertEqual(result["bundleLocalizations"], ["ru"])
        self.assertEqual(
            result["files"],
            ["AdditionalView.swift", "ContentView.swift"],
        )

    def test_rejects_visible_english_action(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sources, info_plist = write_sources(
                Path(temporary),
                extra='Button("Delete") {}',
            )
            result = MODULE.inspect_sources(sources, info_plist)
        self.assertFalse(result["qualified"])
        self.assertIn("Delete", " ".join(result["issues"]))

    def test_rejects_english_accessibility_and_help_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sources, info_plist = write_sources(
                Path(temporary),
                extra=(
                    'Button("Действие") {}\n'
                    '  .accessibilityLabel("More")\n'
                    '  .help("Show settings")'
                ),
            )
            result = MODULE.inspect_sources(sources, info_plist)
        self.assertFalse(result["qualified"])
        issues = " ".join(result["issues"])
        self.assertIn("More", issues)
        self.assertIn("Show", issues)

    def test_scans_every_shipped_swift_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sources, info_plist = write_sources(Path(temporary))
            nested = sources / "Feature"
            nested.mkdir()
            (nested / "LaterFeature.swift").write_text(
                'ContentUnavailableView("Unknown")',
                encoding="utf-8",
            )
            result = MODULE.inspect_sources(sources, info_plist)
        self.assertFalse(result["qualified"])
        self.assertIn("Feature/LaterFeature.swift", result["files"])
        self.assertIn("Unknown", " ".join(result["issues"]))

    def test_rejects_non_russian_bundle_development_region(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sources, info_plist = write_sources(Path(temporary))
            with info_plist.open("wb") as stream:
                plistlib.dump(
                    {
                        "CFBundleDevelopmentRegion": "en",
                        "CFBundleLocalizations": ["ru"],
                    },
                    stream,
                )
            result = MODULE.inspect_sources(sources, info_plist)
        self.assertFalse(result["qualified"])
        self.assertIn("CFBundleDevelopmentRegion", " ".join(result["issues"]))

    def test_rejects_missing_russian_bundle_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources, info_plist = write_sources(root)
            (root / "ru.lproj" / "Localizable.strings").unlink()
            result = MODULE.inspect_sources(sources, info_plist)
        self.assertFalse(result["qualified"])
        self.assertIn("Localizable.strings", " ".join(result["issues"]))

    def test_rejects_missing_required_technical_disclosure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sources, info_plist = write_sources(Path(temporary))
            path = sources / "ContentView.swift"
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    'Button("Технические сведения") {}\n',
                    "",
                ),
                encoding="utf-8",
            )
            result = MODULE.inspect_sources(sources, info_plist)
        self.assertFalse(result["qualified"])
        self.assertIn("Технические сведения", " ".join(result["issues"]))


if __name__ == "__main__":
    unittest.main()
