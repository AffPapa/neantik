import importlib.util
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


def write_sources(root: Path, *, extra: str = "") -> Path:
    sources = root / "Sources"
    common = "\n".join(
        f'Button("{action}") {{}}' for action in MODULE.REQUIRED_ACTIONS
    )
    for filename in MODULE.UI_FILES:
        sources.mkdir(parents=True, exist_ok=True)
        (sources / filename).write_text(
            common + "\n" + extra,
            encoding="utf-8",
        )
    return sources


class VerifyDirectUiLocalizationTests(unittest.TestCase):
    def test_accepts_required_russian_actions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = MODULE.inspect_sources(
                write_sources(Path(temporary))
            )
        self.assertTrue(result["qualified"])

    def test_rejects_visible_english_action(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = MODULE.inspect_sources(
                write_sources(Path(temporary), extra='Button("Delete") {}')
            )
        self.assertFalse(result["qualified"])
        self.assertIn("Delete", " ".join(result["issues"]))

    def test_rejects_missing_required_technical_disclosure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sources = write_sources(Path(temporary))
            for filename in MODULE.UI_FILES:
                path = sources / filename
                path.write_text(
                    path.read_text(encoding="utf-8").replace(
                        'Button("Технические сведения") {}\n',
                        "",
                    ),
                    encoding="utf-8",
                )
            result = MODULE.inspect_sources(sources)
        self.assertFalse(result["qualified"])
        self.assertIn("Технические сведения", " ".join(result["issues"]))


if __name__ == "__main__":
    unittest.main()
